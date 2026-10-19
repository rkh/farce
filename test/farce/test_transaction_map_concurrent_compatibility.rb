# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestTransactionMapConcurrentCompatibility < Test
    MAP_TYPES = [Map, Strict::Map, Unshared::Map, Local::Map].freeze
    OPERATIONS = [
      [:put, %i[key new]], [:get_and_set, %i[key new]],
      [:compute_if_absent, [:missing]], [:compute, [:key]],
      [:store_if_present, [:key]], [:compute_if_present, [:key]],
      [:merge_pair, %i[key initial]], [:replace_pair, %i[key old new]],
      [:delete_pair, %i[key old]], [:fetch_or_store, %i[missing new]],
      [:put_if_absent, %i[missing new]], [:replace_if_exists, %i[key new]]
    ]

    def test_compatibility_methods_stage_changes_and_commit_or_abort_together
      MAP_TYPES.each do |type|
        [true, false].each do |commit|
          initial = { nil_value: nil, false_value: false }
          map = type.new(initial)
          result = Farce.transaction(retries: 0) do |tx|
            view = tx[map]

            assert_instance_of Transaction::Map, view
            assert_equal 1, view.put(:value, 1)
            assert_equal 1, view.compute_if_absent(:value) { flunk "existing key" }
            assert_equal 2, view.compute_if_absent(:missing) { 2 }
            assert_nil view.compute_if_absent(:nil_value) { flunk "existing nil" }
            assert_equal 3, view.store_if_present(:missing) { |value| value + 1 }
            assert_equal 4, view.compute_if_present(:missing) { |value| value + 1 }
            assert_nil(view.compute_if_present(:absent) { flunk "missing key" })
            refute view.key?(:absent)
            assert_equal :from_nil, view.compute_if_present(:nil_value) { |value| value.nil? ? :from_nil : :wrong }
            assert_equal 2, view.compute(:value) { |value| value + 1 }
            assert_equal 3, view.merge_pair(:value, 0) { |value| value + 1 }
            assert_equal 7, view.merge_pair(:inserted, 7) { flunk "missing key" }
            assert_same true, view.replace_pair(:value, 3, 4)
            assert_equal 4, view.get_and_set(:value, 5)
            assert_nil view.get_and_set(:new, nil)
            assert view.key?(:new)
            assert_same true, view.delete_pair(:new, nil)
            assert_same true, view.delete_pair(:false_value, false)
            assert_same true, view.delete_pair(:value, 5)
            assert_equal({ nil_value: :from_nil, missing: 4, inserted: 7 }, view.to_h)
            assert_equal initial, map.to_h
            tx.abort! unless commit
          end

          assert_equal commit, result, type.name
          expected = commit ? { nil_value: :from_nil, missing: 4, inserted: 7 } : initial

          assert_equal expected, map.to_h, type.name
        end
      end
    end

    def test_default_and_conditional_methods_stage_changes_and_commit_or_abort_together
      MAP_TYPES.each do |type|
        [true, false].each do |commit|
          initial = { nil_value: nil, false_value: false, value: :old }
          map = type.new(initial)
          result = Farce.transaction(retries: 0) do |tx|
            view = tx[map]

            assert_nil view.fetch_or_store(:nil_value, :unused)
            assert_same false, view.fetch_or_store(:false_value, :unused)
            assert_equal :default, view.fetch_or_store(:default, :default)
            assert_equal :block, view.fetch_or_store(:block, :unused) { |key| key }
            assert_equal :default, view.put_if_absent(:default, :unused)
            assert_nil view.put_if_absent(:inserted, :new)
            assert_equal :old, view.replace_if_exists(:value, :changed)
            assert_nil view.replace_if_exists(:nil_value, :from_nil)
            assert_nil view.replace_if_exists(:absent, :unused)
            refute view.key?(:absent)
            assert_equal initial, map.to_h
            tx.abort! unless commit
          end

          assert_equal commit, result
          expected = commit ? {
            nil_value: :from_nil, false_value: false, value: :changed, default: :default, block: :block, inserted: :new,
          } : initial

          assert_equal expected, map.to_h, type.name
        end
      end
    end

    def test_default_and_conditional_methods_normalize_keys_once
      MAP_TYPES.each do |type|
        map = type.new(normalize_keys: :succ)

        assert(Farce.transaction do |tx|
          view = tx[map]

          assert_equal 1, view.fetch_or_store(1) { |key| key }
          assert_equal 1, view.put_if_absent(1, :unused)
          assert_nil view.put_if_absent(2, :new)
          assert_equal 1, view.replace_if_exists(1, :changed)
          assert_equal({ 2 => :changed, 3 => :new }, view.to_h)
          assert_empty map
        end)
        assert_equal({ 2 => :changed, 3 => :new }, map.to_h)
      end
    end

    def test_fetch_or_store_reads_a_frozen_participant_without_staging_writes
      MAP_TYPES.each do |type|
        map = type.new({ key: :old }).freeze

        assert(Farce.transaction do |tx|
          assert_equal :old, tx[map].fetch_or_store(:key, :unused)
        end)
      end
    end

    def test_compatibility_methods_normalize_keys_once
      MAP_TYPES.each do |type|
        map = type.new(normalize_keys: :succ)

        assert(Farce.transaction do |tx|
          view = tx[map]

          assert_equal 1, view.put(1, 1)
          assert_equal 1, view.compute_if_absent(1) { flunk "existing key" }
          assert_equal 2, view.compute(1) { |value| value + 1 }
          assert_equal 3, view.store_if_present(1) { |value| value + 1 }
          assert_equal 4, view.compute_if_present(1) { |value| value + 1 }
          assert_equal 5, view.merge_pair(1, 0) { |value| value + 1 }
          assert_same true, view.replace_pair(1, 5, 6)
          assert_equal 6, view.get_and_set(1, 7)
          assert_equal({ 2 => 7 }, view.to_h)
          assert_same true, view.delete_pair(1, 7)
          assert_empty view
        end)
        assert_empty map
      end
    end

    def test_conditional_comparisons_honor_identity_and_discard_failed_attempts
      MAP_TYPES.each do |type|
        %i[replace_pair delete_pair].each do |method|
          stored = String.new("value").freeze
          equal = String.new("value").freeze
          map = type.new({ key: stored }, compare_values_by_identity: true)
          arguments = method == :replace_pair ? [:key, equal, :new] : [:key, equal]

          refute(Farce.transaction(retries: 0) do |tx|
            tx[map].put(:other, :staged)

            assert_same false, tx[map].public_send(method, *arguments)
          end)
          assert_equal({ key: stored }, map.to_h)
          arguments[1] = stored

          assert(Farce.transaction { |tx| assert_same true, tx[map].public_send(method, *arguments) })
          assert_equal(method == :replace_pair ? { key: :new } : {}, map.to_h)
        end
      end
    end

    def test_compatibility_methods_reject_closed_wrappers
      MAP_TYPES.each do |type|
        map = type.new({ key: :old })
        view = nil

        assert(Farce.transaction { |tx| view = tx[map] })
        OPERATIONS.each do |method, arguments|
          assert_raises(Transaction::ClosedError) { perform_operation(view, method, arguments) }
        end
        assert_equal({ key: :old }, map.to_h)
      end
    end

    def test_compatibility_methods_reject_frozen_participants
      MAP_TYPES.each do |type|
        OPERATIONS.each do |method, arguments|
          map = type.new({ key: :old }).freeze

          assert_raises(FrozenError) do
            Farce.transaction { |tx| perform_operation(tx[map], method, arguments) }
          end
          assert_equal({ key: :old }, map.to_h)
        end
      end
    end

    def test_block_failures_discard_earlier_staged_writes
      MAP_TYPES.each do |type|
        %i[fetch_or_store compute_if_absent compute store_if_present compute_if_present merge_pair].each do |method|
          map = type.new({ key: :old })
          key = %i[fetch_or_store compute_if_absent put_if_absent].include?(method) ? :missing : :key
          arguments = method == :merge_pair ? [key, :initial] : [key]

          refute(Farce.transaction(retries: 0) do |tx|
            view = tx[map]
            view.put(:other, :staged)

            assert_raises(RuntimeError) { view.public_send(method, *arguments) { raise "failed" } }
          end)
          assert_equal({ key: :old }, map.to_h)
        end
      end
    end

    def test_conditional_deletion_validates_the_original_entry
      MAP_TYPES.each do |type|
        map = type.new({ key: :old })

        refute(Farce.transaction(retries: 0) do |tx|
          assert_same true, tx[map].delete_pair(:key, :old)
          map[:key] = :external
        end)
        assert_equal :external, map[:key]
      end
    end

    def test_compatibility_methods_preserve_value_modes
      methods = %i[
        put compute_if_absent compute store_if_present compute_if_present merge_pair replace_pair get_and_set
        fetch_or_store put_if_absent replace_if_exists
      ]
      block_methods = %i[fetch_or_store compute_if_absent compute store_if_present compute_if_present merge_pair]
      methods.each do |method|
        map = Map.new({ key: :old }, mode: :local)
        source = ModePayload.new(:new)
        key = %i[fetch_or_store compute_if_absent put_if_absent].include?(method) ? :missing : :key
        arguments = case method
                    when :put, :get_and_set, :fetch_or_store, :put_if_absent, :replace_if_exists then [key, source]
                    when :merge_pair then [key, :initial]
                    when :replace_pair then [key, :old, source]
                    else [key]
                    end

        assert(Farce.transaction do |tx|
          view = tx[map]
          callback = block_methods.include?(method) ? ->(*) { source } : nil
          result = view.public_send(method, *arguments, mode: :copy, &callback)
          stored = view[key]

          refute_same source, stored, method.to_s
          assert_equal :new, stored.value
          assert_equal :old, map[:key]
          if method == :replace_pair
            assert_same true, result
          elsif %i[get_and_set replace_if_exists].include?(method)
            assert_equal :old, result
          elsif method == :put_if_absent
            assert_nil result
          else
            assert_same stored, result
          end

          assert_same true, view.delete_pair(key, ModePayload.new(:new))
        end)
        expected = %i[fetch_or_store compute_if_absent put_if_absent].include?(method) ? { key: :old } : {}

        assert_equal expected, map.to_h
        assert_equal :new, source.value
      end
    end

    private

    def perform_operation(view, method, arguments)
      if %i[compute_if_absent compute store_if_present compute_if_present merge_pair].include?(method)
        view.public_send(method, *arguments) { :new }
      else
        view.public_send(method, *arguments)
      end
    end
  end
end
