# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "timeout"

module Farce
  class TestMapConcurrentCompatibility < Test
    MAP_TYPES = [
      Map, WeakKeyMap, WeakValueMap, WeakMap, Strict::Map, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap,
      Unshared::Map, Unshared::WeakKeyMap, Unshared::WeakValueMap, Unshared::WeakMap,
      Local::Map, Local::WeakKeyMap, Local::WeakValueMap, Local::WeakMap
    ].freeze

    def test_put_returns_the_stored_value
      MAP_TYPES.each do |type|
        map = type.new
        [:value, false, nil].each do |value|
          result = map.put(:key, value)
          if value.nil?
            assert_nil result, type.name
            assert_nil map[:key], type.name
          else
            assert_same value, result, type.name
            assert_same value, map[:key], type.name
          end

          assert map.key?(:key), "#{type} operation failed"
        end
      end
    end

    def test_fetch_or_store_preserves_present_values_and_stores_defaults
      MAP_TYPES.each do |type|
        map = type.new({ nil_value: nil, false_value: false, value: :old })

        assert_nil(map.fetch_or_store(:nil_value, :unused) { flunk "existing nil" })
        assert_same false, map.fetch_or_store(:false_value, :unused)
        assert_equal :old, map.fetch_or_store(:value) { flunk "existing key" }
        assert_nil map.fetch_or_store(:new_nil, nil)
        assert map.key?(:new_nil)
        assert_same false, map.fetch_or_store(:new_false, false)
        assert map.key?(:new_false)
        assert_equal :default, map.fetch_or_store(:missing, :default)
        assert_equal :default, map[:missing]
        assert_equal :block, map.fetch_or_store(:block, :unused) { |key| key }
        error = assert_raises(KeyError) { map.fetch_or_store(:absent) }

        assert_same map, error.receiver
        assert_equal :absent, error.key
        refute map.key?(:absent)
        assert_raises(ArgumentError) { map.fetch_or_store(:value, 1, 2) }
      end
    end

    def test_fetch_or_store_allows_a_write_from_its_block
      MAP_TYPES.each do |type|
        map = type.new
        result = map.fetch_or_store(:key) do |key|
          map.put(key, :intermediate)
          :final
        end

        assert_equal :final, result, type.name
        assert_equal :final, map[:key], type.name
      end
    end

    def test_put_if_absent_returns_the_previous_value_and_inserts_only_missing_keys
      MAP_TYPES.each do |type|
        map = type.new({ nil_value: nil, false_value: false, value: :old })

        assert_nil map.put_if_absent(:nil_value, :unused)
        assert_nil map[:nil_value]
        assert_same false, map.put_if_absent(:false_value, :unused)
        assert_same false, map[:false_value]
        assert_equal :old, map.put_if_absent(:value, :unused)
        assert_equal :old, map[:value]
        assert_nil map.put_if_absent(:missing, :inserted)
        assert_equal :inserted, map[:missing]
        assert_nil map.put_if_absent(:new_nil, nil)
        assert map.key?(:new_nil)
      end
    end

    def test_replace_if_exists_returns_the_previous_value_and_skips_missing_keys
      MAP_TYPES.each do |type|
        map = type.new({ nil_value: nil, false_value: false, value: :old })

        assert_nil map.replace_if_exists(:missing, :unused)
        refute map.key?(:missing)
        assert_nil map.replace_if_exists(:nil_value, :from_nil)
        assert_equal :from_nil, map[:nil_value]
        assert_same false, map.replace_if_exists(:false_value, :from_false)
        assert_equal :from_false, map[:false_value]
        assert_equal :old, map.replace_if_exists(:value, nil)
        assert_nil map[:value]
        assert map.key?(:value)
      end
    end

    def test_default_and_conditional_methods_normalize_keys_once
      MAP_TYPES.each do |type|
        map = type.new(normalize_keys: :succ)
        arguments = nil
        result = map.fetch_or_store(1) do |*args|
          arguments = args
          :first
        end

        assert_equal [1], arguments, type.name
        assert_equal :first, result
        assert_equal :first, map.fetch_or_store(1, :unused)
        assert_equal :first, map.put_if_absent(1, :unused)
        assert_nil map.put_if_absent(2, :second)
        assert_equal :first, map.replace_if_exists(1, :changed)
        assert_nil map.replace_if_exists(3, :unused)
        assert_equal({ 2 => :changed, 3 => :second }, map.to_h, type.name)
      end
    end

    def test_default_and_conditional_methods_preserve_transfer_modes
      [Map, WeakKeyMap].each do |type|
        %i[fetch_or_store put_if_absent replace_if_exists].each do |method|
          map = type.new({ key: :old }, mode: :local)
          value = ModePayload.new(:replacement)
          key = method == :replace_if_exists ? :key : :missing
          result = map.public_send(method, key, value, mode: :copy)
          stored = map[key]
          value.value = :changed

          assert_equal :replacement, stored.value, "#{type}##{method}"
          refute_same value, stored
          if method == :fetch_or_store
            assert_same stored, result
          elsif method == :put_if_absent
            assert_nil result
          else
            assert_equal :old, result
          end
        end
      end
    end

    def test_replace_if_exists_unwraps_the_previous_managed_value
      [Map, WeakKeyMap].each do |type|
        map = type.new({ key: ModePayload.new(:old) }, mode: :copy)
        previous = map[:key]
        result = map.replace_if_exists(:key, ModePayload.new(:new))

        assert_same previous, result, type.name
        assert_equal :old, result.value
        assert_equal :new, map[:key].value
      end
    end

    def test_replace_if_exists_validates_weak_value_modes_even_without_a_write
      [WeakValueMap, WeakMap].each do |type|
        map = type.new({ key: :old })

        assert_raises(ArgumentError) { map.replace_if_exists(:missing, nil, mode: :copy) }
        assert_raises(ArgumentError) { map.replace_if_exists(:key, nil, mode: :copy) }
        assert_equal({ key: :old }, map.to_h)
      end
    end

    def test_conditional_methods_do_not_prepare_unused_values
      [Map, WeakKeyMap].each do |type|
        map = type.new({ key: :old }, mode: :move)
        value = ModePayload.new(:available)

        assert_equal :old, map.fetch_or_store(:key, value)
        assert_equal :old, map.put_if_absent(:key, value)
        assert_nil map.replace_if_exists(:missing, value)
        assert_equal :available, value.value
      end
    end

    def test_concurrent_put_if_absent_has_one_successful_insertion
      [Map, Strict::Map, Unshared::Map, WeakKeyMap, Strict::WeakMap, Unshared::WeakMap].each do |type|
        map = type.new
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = 4.times.map do |index|
          Thread.new do
            ready << true
            start.pop
            map.put_if_absent(:key, index)
          end
        end
        begin
          Timeout.timeout(5) { workers.size.times { ready.pop } }
          workers.size.times { start << true }
          workers.each { assert it.join(5), "#{type} insertion did not finish" }
          results = workers.map(&:value)

          assert_equal 1, results.count(nil), type.name
          assert_equal [map[:key]] * 3, results.compact, type.name
        ensure
          workers.each(&:kill)
          workers.each(&:join)
        end
      end
    end

    def test_compute_if_absent_preserves_existing_nil_and_false
      MAP_TYPES.each do |type|
        map = type.new({ nil_value: nil, false_value: false, value: :existing })
        { nil_value: nil, false_value: false, value: :existing }.each do |key, value|
          result = map.compute_if_absent(key) { flunk "block called for #{type} existing key" }

          if value.nil?
            assert_nil result, type.name
          else
            assert_same value, result, type.name
          end
        end
        arguments = nil
        result = map.compute_if_absent(:missing) do |*args|
          arguments = args
          :inserted
        end

        assert_equal :inserted, result, type.name
        assert_empty arguments
        assert_equal :inserted, map[:missing], type.name
      end
    end

    def test_compute_yields_the_current_value_and_stores_its_result
      MAP_TYPES.each do |type|
        map = type.new({ nil_value: nil, false_value: false, value: 3 })
        { missing: nil, nil_value: nil, false_value: false, value: 3 }.each do |key, value|
          arguments = nil
          result = map.compute(key) do |*args|
            arguments = args
            :replacement
          end

          assert_equal [value], arguments, type.name
          assert_equal :replacement, result, type.name
          assert_equal :replacement, map[key], type.name
        end
      end
    end

    def test_merge_pair_inserts_without_calling_the_block_and_updates_present_keys
      MAP_TYPES.each do |type|
        map = type.new({ nil_value: nil, false_value: false, value: 3 })

        assert_equal 5, map.merge_pair(:missing, 5) { flunk "block called for #{type} missing key" }
        assert_equal 5, map[:missing], type.name
        { nil_value: nil, false_value: false, value: 3 }.each do |key, value|
          arguments = nil
          result = map.merge_pair(key, :unused) do |*args|
            arguments = args
            :replacement
          end

          assert_equal [value], arguments, type.name
          assert_equal :replacement, result, type.name
          assert_equal :replacement, map[key], type.name
        end
      end
    end

    def test_replace_pair_checks_presence_and_returns_a_boolean
      MAP_TYPES.each do |type|
        map = type.new({ key: :old, nil_value: nil, false_value: false })

        refute map.replace_pair(:missing, nil, :replacement), type.name
        refute map.key?(:missing), type.name
        refute map.replace_pair(:key, :wrong, :replacement), type.name
        assert_equal :old, map[:key], type.name
        assert map.replace_pair(:key, :old, :replacement), "#{type} operation failed"
        assert_equal :replacement, map[:key], type.name
        assert map.replace_pair(:nil_value, nil, false), "#{type} operation failed"
        assert_same false, map[:nil_value], type.name
        assert map.replace_pair(:false_value, false, nil), "#{type} operation failed"
        assert_nil map[:false_value], type.name
        assert map.key?(:false_value), "#{type} operation failed"
      end
    end

    def test_replace_pair_honors_value_comparison_options
      MAP_TYPES.each do |type|
        stored = String.new("value").freeze
        equal = String.new("value").freeze
        map = type.new({ key: stored })

        assert map.replace_pair(:key, equal, :replacement), "#{type} operation failed"
        map = type.new({ key: stored }, compare_values_by_identity: true)

        refute map.replace_pair(:key, equal, :replacement), type.name
        assert_same stored, map[:key], type.name
        assert map.replace_pair(:key, stored, :replacement), "#{type} operation failed"
      end
    end

    def test_store_and_compute_if_present_skip_missing_keys
      MAP_TYPES.each do |type|
        %i[store_if_present compute_if_present].each do |method|
          map = type.new

          assert_nil(map.public_send(method, :missing) { flunk "block called for #{type} missing key" })
          refute map.key?(:missing), type.name
          assert_empty map
        end
      end
    end

    def test_store_and_compute_if_present_yield_existing_nil_and_false
      MAP_TYPES.each do |type|
        %i[store_if_present compute_if_present].each do |method|
          { nil => :from_nil, false => :from_false, 3 => :from_value }.each do |value, replacement|
            map = type.new({ key: value })
            arguments = nil
            result = map.public_send(method, :key) do |*args|
              arguments = args
              replacement
            end

            assert_equal [value], arguments, "#{type}##{method}"
            assert_equal replacement, result, "#{type}##{method}"
            assert_equal replacement, map[:key], "#{type}##{method}"
          end
        end
      end
    end

    def test_delete_pair_checks_presence_and_preserves_mismatches
      MAP_TYPES.each do |type|
        map = type.new({ key: :old, nil_value: nil, false_value: false })

        assert_same false, map.delete_pair(:missing, nil), type.name
        assert_same false, map.delete_pair(:key, :wrong), type.name
        assert_equal({ key: :old, nil_value: nil, false_value: false }, map.to_h)
        assert_same true, map.delete_pair(:key, :old), type.name
        refute map.key?(:key), type.name
        assert_same true, map.delete_pair(:nil_value, nil), type.name
        refute map.key?(:nil_value), type.name
        assert_same true, map.delete_pair(:false_value, false), type.name
        assert_empty map
      end
    end

    def test_delete_pair_honors_value_comparison_options
      MAP_TYPES.each do |type|
        stored = String.new("value").freeze
        equal = String.new("value").freeze
        map = type.new({ key: stored })

        assert_same true, map.delete_pair(:key, equal), type.name
        map = type.new({ key: stored }, compare_values_by_identity: true)

        assert_same false, map.delete_pair(:key, equal), type.name
        assert_same stored, map[:key], type.name
        assert_same true, map.delete_pair(:key, stored), type.name
        assert_empty map
      end
    end

    def test_delete_pair_compares_managed_values_without_changing_expected
      [Map, WeakKeyMap].each do |type|
        %i[local copy move].each do |mode|
          map = type.new({ key: ModePayload.new(:value) }, mode:)
          expected = ModePayload.new(:value)

          assert_same true, map.delete_pair(:key, expected), "#{type} #{mode}"
          assert_equal :value, expected.value
          refute_predicate expected, :frozen?
          assert_empty map
        end
      end
    end

    def test_get_and_set_returns_the_previous_value
      MAP_TYPES.each do |type|
        [:old, nil, false].each do |value|
          map = type.new({ key: value })

          previous = map.get_and_set(:key, :replacement)
          if value.nil?
            assert_nil previous, type.name
          else
            assert_same value, previous, type.name
          end

          assert_equal :replacement, map[:key], type.name
          assert_equal :replacement, map.get_and_set(:key, nil), type.name
          assert_nil map[:key], type.name
          assert map.key?(:key), "#{type} operation failed"
        end
      end
    end

    def test_get_and_set_inserts_an_absent_key
      MAP_TYPES.each do |type|
        map = type.new
        previous = Timeout.timeout(5) { map.get_and_set(:missing, :inserted) }

        assert_nil previous, type.name
        assert_equal :inserted, map[:missing], type.name
      end
    end

    def test_compatibility_methods_normalize_keys
      MAP_TYPES.each do |type|
        map = type.new(normalize_keys: :succ)

        assert_equal 1, map.put(1, 1)
        assert_equal 1, map.compute_if_absent(1) { flunk "existing key" }
        assert_equal 2, map.compute(1) { |value| value + 1 }
        assert_equal 3, map.compute_if_present(1) { |value| value + 1 }
        assert_equal 4, map.store_if_present(1) { |value| value + 1 }
        assert_equal 5, map.merge_pair(1, 0) { |value| value + 1 }
        assert map.replace_pair(1, 5, 6)
        assert_equal 6, map.get_and_set(1, 7)
        assert_equal({ 2 => 7 }, map.to_h, type.name)
        assert_same true, map.delete_pair(1, 7), type.name
        assert_empty map
      end
    end

    def test_compatibility_aliases_preserve_value_modes
      [Map, WeakKeyMap].each do |type|
        %i[put compute_if_absent compute merge_pair replace_pair].each do |method|
          map = type.new({ key: :old }, mode: :local)
          value = ModePayload.new(:replacement)
          result = case method
                   when :put then map.put(:key, value)
                   when :compute_if_absent then map.compute_if_absent(:missing) { value }
                   when :compute then map.compute(:key) { value }
                   when :merge_pair then map.merge_pair(:key, :unused) { value }
                   when :replace_pair then map.replace_pair(:key, :old, value)
                   end

          if method == :replace_pair
            assert_same true, result, "#{type}##{method}"
          else
            assert_same value, result, "#{type}##{method}"
          end
          key = method == :compute_if_absent ? :missing : :key

          assert_same value, map[key], "#{type}##{method}"
        end
      end
    end

    def test_compatibility_methods_forward_mode_overrides
      [Map, WeakKeyMap].each do |type|
        %i[put compute_if_absent compute merge_pair replace_pair get_and_set].each do |method|
          map = type.new({ key: :old }, mode: :local)
          value = ModePayload.new(:replacement)
          result = case method
                   when :put then map.put(:key, value, mode: :copy)
                   when :compute_if_absent then map.compute_if_absent(:missing, mode: :copy) { value }
                   when :compute then map.compute(:key, mode: :copy) { value }
                   when :merge_pair then map.merge_pair(:key, :unused, mode: :copy) { value }
                   when :replace_pair then map.replace_pair(:key, :old, value, mode: :copy)
                   when :get_and_set then map.get_and_set(:key, value, mode: :copy)
                   end
          key = method == :compute_if_absent ? :missing : :key
          stored = map[key]
          value.value = :changed

          refute_same value, stored, "#{type}##{method}"
          assert_equal :replacement, stored.value, "#{type}##{method}"
          if method == :replace_pair
            assert_same true, result
          elsif method == :get_and_set
            assert_equal :old, result
          else
            assert_same stored, result
          end
        end
      end
    end

    def test_store_and_compute_if_present_return_the_prepared_value
      [Map, WeakKeyMap].each do |type|
        %i[store_if_present compute_if_present].each do |method|
          map = type.new({ key: :old }, mode: :copy)
          value = ModePayload.new(:replacement)
          result = map.public_send(method, :key) { value }

          assert_equal :replacement, result.value, "#{type}##{method}"
          refute_same value, result, "#{type}##{method}"
          assert_same result, map[:key], "#{type}##{method}"
        end
      end
    end

    def test_store_and_compute_if_present_prepare_weak_values
      [WeakValueMap, WeakMap].each do |type|
        %i[store_if_present compute_if_present].each do |method|
          map = type.new({ key: :old }, mode: :make_shareable)
          value = [String.new("replacement")]
          result = map.public_send(method, :key) { value }

          assert_same value, result, "#{type}##{method}"
          assert Ractor.shareable?(result)
          assert_same result, map[:key], "#{type}##{method}"
        end
      end
    end

    def test_store_and_compute_if_present_reject_unshareable_strict_values_and_keys
      [Strict::Map, Strict::WeakKeyMap, Strict::WeakValueMap, Strict::WeakMap].each do |type|
        %i[store_if_present compute_if_present].each do |method|
          map = type.new({ key: :old })
          rejected = ModePayload.new(:rejected)

          assert_raises(Ractor::IsolationError) { map.public_send(method, :key) { rejected } }
          assert_raises(Ractor::IsolationError) { map.public_send(method, rejected) { :value } }
          assert_equal({ key: :old }, map.to_h, "#{type}##{method}")
          assert_equal :usable, map.store(:key, :usable, timeout: 0)
        end
      end
    end

    def test_store_and_compute_if_present_require_a_block
      MAP_TYPES.each do |type|
        %i[store_if_present compute_if_present].each do |method|
          map = type.new({ key: :old })

          assert_raises(LocalJumpError) { map.public_send(method, :key) }
          assert_raises(LocalJumpError) { map.public_send(method, :missing) }
          assert_equal({ key: :old }, map.to_h)
        end
      end
    end

    def test_clear_cancels_store_and_compute_if_present
      MAP_TYPES.each do |type|
        %i[store_if_present compute_if_present].each do |method|
          map = type.new({ key: :old })
          result = map.public_send(method, :key) do
            map.clear
            :stale
          end

          assert_nil result, "#{type}##{method}"
          assert_empty map
        end
      end
    end

    def test_block_exceptions_leave_entries_unchanged_and_release_the_key
      MAP_TYPES.each do |type|
        %i[compute_if_absent compute store_if_present compute_if_present merge_pair].each do |method|
          map = type.new({ key: :old })
          key = method == :compute_if_absent ? :missing : :key
          arguments = method == :merge_pair ? [key, :unused] : [key]
          failure = RuntimeError.new("block failed")
          error = assert_raises(RuntimeError) { map.public_send(method, *arguments) { raise failure } }

          assert_same failure, error
          assert_equal({ key: :old }, map.to_h, "#{type}##{method}")
          assert_equal :usable, map.put(key, :usable, timeout: 0)
          assert_equal :usable, map[key]
        end
      end
    end

    def test_compatibility_methods_respect_timeout_without_calling_blocks
      [Map, Strict::Map, Unshared::Map, WeakKeyMap, Strict::WeakMap, Unshared::WeakMap].each do |type|
        map = type.new({ key: :old })
        entered = Thread::Queue.new
        release = Thread::Queue.new
        worker = Thread.new do
          map.update(:key) do |value|
            entered << true
            release.pop
            value
          end
        end
        begin
          Timeout.timeout(5) { entered.pop }

          assert_equal :busy, map.put(:key, :replacement, timeout: 0) { :busy }
          %i[compute_if_absent compute store_if_present compute_if_present].each do |method|
            assert_nil(map.public_send(method, :key, timeout: 0) { flunk "timed out #{method} called its block" })
          end
          assert_nil(map.merge_pair(:key, :replacement, timeout: 0) { flunk "timed out merge called its block" })
          refute map.replace_pair(:key, :old, :replacement, timeout: 0)
          assert_same false, map.delete_pair(:key, :old, timeout: 0), type.name
          assert_nil map.put_if_absent(:key, :unused, timeout: 0)
          assert_nil map.replace_if_exists(:key, :unused, timeout: 0)
        ensure
          release << true
          worker.kill unless worker.join(5)
          worker.value
        end

        assert_equal :old, map[:key], type.name
      end
    end

    def test_concurrent_get_and_set_returns_each_previous_value_once
      [Map, Strict::Map, Unshared::Map, WeakKeyMap, Strict::WeakMap, Unshared::WeakMap].each do |type|
        map = type.new({ key: 0 })
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = 4.times.map do |index|
          Thread.new do
            ready << true
            start.pop
            20.times.map { |offset| map.get_and_set(:key, (index * 20) + offset + 1) }
          end
        end
        begin
          Timeout.timeout(5) { workers.size.times { ready.pop } }
          workers.size.times { start << true }
          workers.each { assert it.join(5), "#{type} exchange did not finish" }
          observed = workers.flat_map(&:value) << map[:key]

          assert_equal (0..80).to_a, observed.sort, type.name
        ensure
          workers.each(&:kill)
          workers.each(&:join)
        end
      end
    end

    def test_concurrent_replace_if_exists_returns_each_previous_value_once
      [Map, Strict::Map, Unshared::Map, WeakKeyMap, Strict::WeakMap, Unshared::WeakMap].each do |type|
        map = type.new({ key: 0 })
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = 4.times.map do |index|
          Thread.new do
            ready << true
            start.pop
            20.times.map { |offset| map.replace_if_exists(:key, (index * 20) + offset + 1) }
          end
        end
        begin
          Timeout.timeout(5) { workers.size.times { ready.pop } }
          workers.size.times { start << true }
          workers.each { assert it.join(5), "#{type} replacement did not finish" }
          observed = workers.flat_map(&:value) << map[:key]

          assert_equal (0..80).to_a, observed.sort, type.name
        ensure
          workers.each(&:kill)
          workers.each(&:join)
        end
      end
    end

    def test_concurrent_compute_if_present_does_not_lose_updates
      [Map, Strict::Map, Unshared::Map, WeakKeyMap, Strict::WeakMap, Unshared::WeakMap].each do |type|
        map = type.new({ count: 0 })
        ready = Thread::Queue.new
        start = Thread::Queue.new
        workers = 4.times.map do
          Thread.new do
            ready << true
            start.pop
            50.times { map.compute_if_present(:count) { |value| value + 1 } }
          end
        end
        begin
          Timeout.timeout(5) { workers.size.times { ready.pop } }
          workers.size.times { start << true }
          workers.each { assert it.join(5), "#{type} update did not finish" }
          workers.each(&:value)

          assert_equal 200, map[:count], type.name
        ensure
          workers.each(&:kill)
          workers.each(&:join)
        end
      end
    end
  end
end
