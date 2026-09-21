# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestStrongMapCopy < Test
    def test_dup_has_independent_entries
      [Farce::Map, Strict::Map, Unshared::Map].each do |type|
        original = type.new({ present: nil })
        copy = original.dup

        assert_instance_of type, copy
        assert copy.key?(:present)
        copy[:present] = :new
        copy[:added] = :copy

        assert_nil original[:present]
        refute original.key?(:added)
        original[:original] = :source

        refute copy.key?(:original)
        assert_equal 3, copy.store_if_absent(:new_key) { 3 }
        refute original.key?(:new_key)
      end
    end

    def test_clone_has_independent_entries
      [Farce::Map, Strict::Map, Unshared::Map].each do |type|
        original = type.new({ present: :source })
        copy = original.clone
        copy[:present] = :copy

        assert_equal :source, original[:present]
        assert_equal :copy, copy[:present]
      end
    end

    def test_shareable_copies_remain_shareable
      [Farce::Map, Strict::Map].each do |type|
        original = type.new({ present: :source })
        [original.dup, original.clone].each do |copy|
          assert Ractor.shareable?(copy)
          refute_predicate copy, :frozen?
          if Internal.native_ractors?
            worker = Ractor.new(copy) { |map| map[:present] }

            assert_equal :source, worker.respond_to?(:value) ? worker.value : worker.take
          end
          copy[:present] = :copy

          assert_equal :source, original[:present]
        end
        unfrozen = original.clone(freeze: false)

        refute_predicate unfrozen, :frozen?
        assert Ractor.shareable?(unfrozen)
        unfrozen[:present] = :local_copy

        assert_equal :source, original[:present]
      end
    end

    def test_dup_preserves_canonical_keys_without_running_normalizer
      calls = 0
      normalize = proc do |key|
        calls += 1
        "#{key}-#{calls}"
      end
      original = Unshared::Map.new(nil, normalize_keys: normalize)
      original[:entry] = :value
      calls_before_copy = calls
      copy = original.dup

      assert_equal calls_before_copy, calls
      assert_equal original.to_h, copy.to_h
      copy[:new] = :copy

      refute original.to_h.key?("new-#{calls}")
    end

    def test_dup_keeps_mode_and_shares_shallow_values
      original = Farce::Map.new(mode: :raise)
      original.store(:mutable, [], mode: :local)
      copy = original.dup

      assert_equal :raise, copy.mode
      assert_same original[:mutable], copy[:mutable]
      copy[:other] = :new

      refute original.key?(:other)
    end

    def test_dup_does_not_claim_move_value
      original = Farce::Map.new(mode: :move)
      original[:mutable] = []
      envelope = original.instance_variable_get(:@map)[:mutable]

      refute_predicate envelope, :claimed? if Envelope === envelope
      copy = original.dup

      refute_predicate envelope, :claimed? if Envelope === envelope

      assert_same original[:mutable], copy[:mutable]
    end

    def test_dup_preserves_comparison_options
      [Farce::Map, Strict::Map, Unshared::Map].each do |type|
        original = type.new(compare_keys_by_identity: true, compare_values_by_identity: true)
        key = "key"
        original[key] = :value
        copy = original.dup

        assert_predicate copy, :compare_keys_by_identity?
        assert_predicate copy, :compare_values_by_identity?
        assert_equal :value, copy[key]
        assert_nil copy["key".dup.freeze]
      end
    end

    def test_normalized_shareable_copies_keep_canonical_keys
      [Farce::Map, Strict::Map].each do |type|
        normalizer = Ractor.shareable_proc { |key| String === key ? key.upcase : key }
        original = type.new({ "a" => :value }, normalize_keys: normalizer)

        [original.dup, original.clone].each do |copy|
          assert_equal({ "A" => :value }, copy.to_h)
          assert_equal :value, copy["a"]
          copy["b"] = :copy

          refute original.key?("b")
        end
      end
    end

    def test_unshared_copy_shares_mutable_values
      value = []
      original = Unshared::Map.new({ key: value })
      copy = original.dup

      assert_same value, copy[:key]
      copy[:key] << :changed

      assert_equal [:changed], original[:key]
      copy.delete(:key)

      assert_same value, original[:key]
    end

    def test_copy_has_independent_key_reservations
      [Farce::Map, Strict::Map, Unshared::Map].each do |type|
        source = type.new({ key: :old })
        copy = source.dup
        entered = Queue.new
        release = Queue.new
        worker = Thread.new do
          source.update(:key) do
            entered << true
            release.pop
            :source
          end
        end

        assert Timeout.timeout(2) { entered.pop }

        assert_equal :copy, copy.update(:key, timeout: 0) { :copy }
        copy.clear

        assert_equal :old, source[:key]
        release << true

        assert worker.join(2), "source update did not finish"
        assert_equal :source, source[:key]
      ensure
        release << true if release
        worker&.join(2)
      end
    end
  end
end
