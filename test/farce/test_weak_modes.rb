# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWeakModes < Test
    include Helpers::InternalTestHelpers

    TYPES = [WeakAtom, WeakMap, WeakValueMap].freeze
    UNSUPPORTED_MODES = [:copy, :move, :local, :shareable_copy, :proxy, :invalid, false, 1].freeze

    def test_defaults_and_shareability
      TYPES.each do |type|
        container = build(type, :initial)

        assert_equal :raise, container.mode
        assert_equal :initial, read(container)
        assert Ractor.shareable?(container)
        refute_predicate container, :frozen?
      end
    end

    def test_default_rejects_unshareable_values_without_replacing_contents
      TYPES.each do |type|
        value = Unshared::Queue.new
        assert_raises(Ractor::IsolationError) { build(type, value) }
        container = build(type, :initial)

        assert_raises(Ractor::IsolationError) { store(container, value) }
        assert_raises(Ractor::IsolationError) { update(container) { value } }
        assert_raises(Ractor::IsolationError) { cas(container, :initial, value) }
        assert_equal :initial, read(container)
        assert_equal :recovered, update(container) { :recovered }
      end
    end

    def test_modes_are_validated_for_nil_shareable_values_and_skipped_writes
      TYPES.each do |type|
        UNSUPPORTED_MODES.each do |mode|
          assert_raises(ArgumentError) { build(type, nil, mode:) }
          assert_raises(ArgumentError) { build(type, :initial, mode:) }
          container = build(type, :initial)
          assert_raises(ArgumentError) { store(container, nil, mode:) }
          assert_raises(ArgumentError) { swap(container, :replacement, mode:) }
          assert_raises(ArgumentError) { update(container, mode:) { :replacement } }
          assert_raises(ArgumentError) { absent(container, mode:) { flunk "executed rejected block" } }
          assert_raises(ArgumentError) { upsert(container, :initial, mode:) { :replacement } }
          assert_raises(ArgumentError) { cas(container, :missing, :replacement, mode:) }
          assert_equal :initial, read(container)
        end
      end
    end

    def test_make_shareable_preserves_the_original_and_returns_the_stored_value
      TYPES.each do |type|
        value = [Object.new]
        container = build(type, value, mode: :make_shareable)

        assert_same value, read(container)
        assert Ractor.shareable?(value)
        assert_predicate value, :frozen? if Internal.native_ractors?
        replacement = [Object.new]

        assert_same replacement, update(container) { replacement }
        assert_same replacement, read(container)
        assert Ractor.shareable?(replacement)
        assert_equal :make_shareable, container.mode
      end
    end

    def test_per_operation_modes_prepare_only_the_replacement
      TYPES.each do |type|
        container = build(type, :initial)
        value = []

        assert_same value, store(container, value, mode: :make_shareable)
        assert_equal :raise, container.mode
        assert_same value, swap(container, nil)
        container.delete(:key) unless Abstract::WeakAtom === container
        lazy = []

        assert_same lazy, absent(container, mode: :make_shareable) { lazy }
        ignored = Unshared::Queue.new

        assert_same lazy, absent(container) { ignored }
        assert_equal :updated, upsert(container, ignored) { :updated }
        assert_equal :updated, swap(container, nil)
        container.delete(:key) unless Abstract::WeakAtom === container
        initial = []

        assert_same initial, upsert(container, initial, mode: :make_shareable) { flunk "updated absent value" }
        assert_same initial, read(container)
      end
    end

    def test_failed_cas_does_not_prepare_replacement_and_expected_is_untouched
      TYPES.each do |type|
        original = [1].freeze
        container = build(type, original, mode: :make_shareable)
        expected = [2]
        replacement = []

        refute cas(container, expected, replacement)
        refute_predicate expected, :frozen?
        refute_predicate replacement, :frozen?
        assert_same original, read(container)
        expected = [1]

        assert cas(container, expected, replacement)
        refute_predicate expected, :frozen?
        assert_same replacement, read(container)
      end
    end

    def test_identity_comparisons_use_the_stored_object
      TYPES.each do |type|
        original = [1].freeze
        container = build(type, original, compare_by_identity: true)
        expected = [1]

        refute cas(container, expected, :incorrect)
        assert_same original, wait(container, expected, timeout: 0)
        refute_predicate expected, :frozen?
        assert cas(container, original, :replacement)
      end
    end

    def test_waits_compare_mutable_operands_without_preparing_them
      TYPES.each do |type|
        original = [1].freeze
        container = build(type, original, mode: :dedup)
        expected = [1]

        assert_equal :timeout, wait(container, expected, timeout: 0) { :timeout }
        refute_predicate expected, :frozen?
        worker = Thread.new { wait(container, expected, timeout: 2) }
        store(container, :changed)

        assert_equal :changed, worker.value
      ensure
        worker&.kill if worker&.alive?
        worker&.join
      end
    end

    def test_dedup_returns_a_canonical_value_that_can_differ_from_the_input
      return unless Internal.native_ractors?

      canonical = Farce.dedup([String.new("weak modes canonical")])
      TYPES.each do |type|
        input = [String.new("weak modes canonical")]
        container = build(type, nil, mode: :dedup)
        result = store(container, input)

        assert_same canonical, result
        refute_same input, result
        assert_same canonical, read(container)
        assert_same canonical, update(container) { [String.new("weak modes canonical")] }
      end
    end

    def test_existing_shareable_values_and_explicit_envelopes_pass_through
      TYPES.each do |type|
        value = [1].freeze
        container = build(type, value, mode: :dedup)

        assert_same value, read(container)
        envelope = Envelope.new(Object.new, mode: :local)

        assert_same envelope, store(container, envelope)
        assert_same envelope, read(container)
      end
    end

    def test_values_are_collected_with_a_live_or_frozen_container
      TYPES.each do |type|
        %i[raise make_shareable dedup].each do |mode|
          [false, true].each do |freeze_container|
            container = Thread.new do
              value = [Object.new]
              value = Ractor.make_shareable(value) if mode == :raise
              result = build(type, value, mode:)
              result.freeze if freeze_container
              result
            end.value

            assert_collected(container)
          end
        end
      end
    end

    def test_dedup_input_does_not_retain_the_canonical_result
      return unless Internal.native_ractors?

      TYPES.each do |type|
        holder = []
        container = Thread.new do
          canonical = Farce.dedup([String.new("weak modes lifetime")])
          input = [String.new("weak modes lifetime")]
          holder << input
          result = build(type, canonical, mode: :dedup)
          store(result, input)
          result
        end.value

        assert_collected(container)
        assert_equal [["weak modes lifetime"]], holder
      end
    end

    def test_copies_keep_modes_and_independent_freeze_state
      TYPES.each do |type|
        value = [1].freeze
        source = build(type, value, mode: :dedup)
        source.freeze
        duplicate = source.dup
        clone = source.clone

        assert_equal :dedup, duplicate.mode
        refute_predicate duplicate, :frozen?
        assert_predicate clone, :frozen?
        assert_same value, read(duplicate)
        assert_equal :changed, store(duplicate, :changed)
        assert_same value, read(source)
        assert_raises(FrozenError) { store(clone, :changed) }
      end
    end

    def test_failed_block_and_nonlocal_exit_release_updates
      TYPES.each do |type|
        container = build(type, :initial)
        assert_raises(RuntimeError) { update(container) { raise "failed" } }
        result = catch(:abort) { update(container) { throw :abort, :aborted } }

        assert_equal :aborted, result
        assert_equal :initial, read(container)
        assert_equal :recovered, store(container, :recovered)
      end
    end

    def test_transactions_still_reject_weak_storage
      TYPES.each do |type|
        container = build(type, :initial)

        assert_raises(TypeError) do
          Farce.transaction do |transaction|
            transaction[container].store(*write_args(container), :changed)
          end
        end
        assert_equal :initial, read(container)
      end
    end

    def test_freezing_rejects_every_write_without_preparing_values
      TYPES.each do |type|
        container = build(type, :initial, mode: :make_shareable)
        container.freeze
        replacement = []

        assert_raises(FrozenError) { store(container, replacement) }
        assert_raises(FrozenError) { swap(container, replacement) }
        assert_raises(FrozenError) { update(container) { flunk "updated frozen container" } }
        assert_raises(FrozenError) { absent(container) { flunk "initialized frozen container" } }
        assert_raises(FrozenError) { upsert(container, replacement) { flunk "upserted frozen container" } }
        assert_raises(FrozenError) { cas(container, :missing, replacement) }
        assert_raises(FrozenError) { cas(container, :initial, replacement) }
        refute_predicate replacement, :frozen?
        assert_equal :initial, read(container)
      end
    end

    def test_timeout_fallbacks_are_returned_directly
      TYPES.each do |type|
        container = build(type, :initial)
        entered = Thread::Queue.new
        release = Thread::Queue.new
        updater = Thread.new do
          update(container) do |current|
            entered << true
            release.pop
            current
          end
        end
        entered.pop
        fallback = Envelope.new(Object.new, mode: :local)

        assert_same fallback, container.get(*write_args(container), timeout: 0) { fallback }
        assert_same fallback, store(container, :replacement, timeout: 0) { fallback }
        assert_same fallback, swap(container, :replacement, timeout: 0) { fallback }
        assert_same fallback, wait(container, :initial, timeout: 0) { fallback }
        refute cas(container, :initial, :replacement, timeout: 0)
        assert_nil update(container, timeout: 0) { flunk "updated locked container" }
        assert_nil absent(container, timeout: 0) { flunk "initialized locked container" }
        assert_nil upsert(container, :initial, timeout: 0) { flunk "upserted locked container" }
      ensure
        release&.push(true)
        updater&.join
      end
    end

    def test_map_modes_do_not_prepare_keys
      [WeakMap, WeakValueMap].each do |type|
        map = type.new(mode: :make_shareable)
        key = Unshared::Queue.new
        value = []

        assert_raises(Ractor::IsolationError) { map.store(key, value) }
        refute_predicate value, :frozen?
        assert_empty map
      end
    end

    def test_weak_key_lifetime_differs_from_strong_key_lifetime
      value = Object.new.freeze
      weak, strong, key_reference = Thread.new do
        key = Object.new.freeze
        [WeakMap.new({ key => value }), WeakValueMap.new({ key => value }), WeakValue.new(key)]
      end.value
      5.times { GC.start }

      assert_equal 1, weak.size
      assert_equal 1, strong.size
      assert Thread.new { key_reference.alive? }.value
      strong.clear
      50.times do
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        break unless Thread.new { key_reference.alive? }.value
        sleep 0.01
      end

      refute Thread.new { key_reference.alive? }.value
      assert_empty weak
      assert Ractor.shareable?(value)
    end

    def test_modes_prepare_values_in_the_requesting_ractor
      return unless Internal.native_ractors?

      TYPES.each do |type|
        container = build(type, :initial, mode: :make_shareable)
        worker = Ractor.new(container) do |shared|
          result = if Abstract::WeakAtom === shared
                     shared.update { [Ractor.current.__id__] }
                   else
                     shared.update(:key) { [Ractor.current.__id__] }
                   end
          [result, result.equal?(Abstract::WeakAtom === shared ? shared.value : shared[:key])]
        end
        result, identical = ractor_value(worker)

        assert identical
        assert_same result, read(container)
      end
    end

    private

    def build(type, value, **)
      type == WeakAtom ? type.new(value, **) : type.new({ key: value }, **)
    end

    def write_args(container) = Abstract::WeakAtom === container ? [] : [:key]
    def read(container) = Abstract::WeakAtom === container ? container.value : container[:key]
    def store(container, value, **, &) = container.store(*write_args(container), value, **, &)
    def swap(container, value, **, &) = container.swap(*write_args(container), value, **, &)
    def update(container, **, &) = container.update(*write_args(container), **, &)
    def absent(container, **, &) = container.store_if_absent(*write_args(container), **, &)
    def upsert(container, value, **, &) = container.upsert(*write_args(container), value, **, &)

    def cas(container, expected, replacement, **)
      container.compare_and_set(*write_args(container), expected, replacement, **)
    end

    def wait(container, expected, **, &) = container.wait_until_changed(*write_args(container), expected, **, &)

    def assert_collected(container)
      50.times do
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        collected = Thread.new { read(container).nil? }.value
        if collected
          assert_nil read(container)
          assert_empty container unless Abstract::WeakAtom === container
          return
        end
        sleep 0.01
      end

      flunk "weak value remained reachable after repeated collections"
    end
  end

  class TestWeakModeMapContract < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakMapContract

    private def map_classes = [WeakMap, WeakValueMap]
  end
end
