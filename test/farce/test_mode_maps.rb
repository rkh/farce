# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestModeMaps < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakMapContract

    class ObservedWaitValue
      include Unshareable

      def initialize(entered, resume)
        @entered = entered
        @resume = resume
      end

      def ==(other)
        @entered << :compared
        @resume.pop
        other == :expected
      end
    end

    MAP_CLASSES = [Map, WeakKeyMap].freeze

    def map_classes = MAP_CLASSES

    def run(...) = Timeout.timeout(10) { super }

    def test_initialization_defaults_and_shareability
      MAP_CLASSES.each do |klass|
        map = klass.new

        assert_equal :copy, map.mode
        refute_predicate map, :compare_keys_by_identity?
        refute_predicate map, :compare_values_by_identity?
        assert_predicate map, :shareable_keys?
        assert_predicate map, :shareable_values?
        assert_kind_of Abstract::ConcurrentMap, map
        refute_predicate map, :frozen?
        assert_predicate map, :ractor_shareable?
        assert Ractor.shareable?(map)
      end

      refute_predicate Map.new, :weak_keys?
      assert_predicate WeakKeyMap.new, :weak_keys?
    end

    def test_initialization_accepts_value_modes_and_comparison_options
      MAP_CLASSES.each do |klass|
        map = klass.new(
          mode:                     :local,
          compare_by_identity:      true,
          compare_keys_by_identity: false,
        )

        assert_equal :local, map.mode
        refute_predicate map, :compare_keys_by_identity?
        assert_predicate map, :compare_values_by_identity?

        error = assert_raises(ArgumentError) { klass.new(mode: :invalid) }
        assert_equal "invalid mode: :invalid", error.message
      end
    end

    def test_keys_are_stored_directly_and_must_be_shareable
      MAP_CLASSES.each do |klass|
        key = shared_string("key")
        map = klass.new(mode: :move)

        map[key] = ModePayload.new(:value)

        assert_same key, map.getkey(shared_string("key"))
        refute_operator Ractor::MovedObject, :===, key

        unshareable_key = ModePayload.new(:key)
        error = assert_raises(Ractor::IsolationError) { map[unshareable_key] = :rejected }

        assert_match(/key must be Ractor-shareable/, error.message)
        initial_key = ModePayload.new(:initial)

        assert_raises(Ractor::IsolationError) { klass.new({ initial_key => :rejected }) }
        assert_equal 1, map.size
      end
    end

    def test_initial_values_use_copy_mode_and_are_automatically_unwrapped
      MAP_CLASSES.each do |klass|
        source = ModePayload.new(:original)
        map = klass.new({ key: source })
        envelope = map.instance_variable_get(:@map)[:key]

        source.value = :changed

        assert_instance_of Envelope::Copy, envelope
        refute_same source, map[:key]
        assert_equal :original, map[:key].value
        assert_same map[:key], map.get(:key)
      end
    end

    def test_reads_and_mutations_automatically_unwrap_managed_values
      MAP_CLASSES.each do |klass|
        first = ModePayload.new(:first)
        second = ModePayload.new(:second)
        map = klass.new(mode: :local)

        assert_same first, map.store(:key, first)
        assert_same first, map[:key]
        assert_same first, map.get(:key)
        assert_same first, map.fetch(:key)
        assert_same first, map.each.to_h[:key]
        assert_same first, map.each_value.first
        assert_same first, map.swap(:key, second)
        assert_same second, map[:key]
        assert_same second, map.delete(:key)
        refute map.key?(:key)
      end
    end

    def test_explicit_envelopes_are_stored_and_returned_as_values
      MAP_CLASSES.each do |klass|
        payload = ModePayload.new(:payload)
        first = Envelope.new(payload, mode: :local)
        second = Envelope.new(:replacement, mode: :local)
        map = klass.new({ key: first })

        assert_same first, map[:key]
        assert_same first, map.get(:key)
        assert_same first, map.fetch(:key)
        assert_same first, map.each.to_h[:key]
        assert_same first, map.each_value.first
        assert_same first, map.swap(:key, second)
        assert_same second, map.delete(:key)
        assert_same payload, first.value
      end
    end

    def test_store_mode_override_copies_values_without_changing_the_default
      MAP_CLASSES.each do |klass|
        source = ModePayload.new(:original)
        map = klass.new(mode: :local)
        stored = map.store(:key, source, mode: :copy)

        source.value = :changed

        refute_same source, stored
        assert_equal :original, stored.value
        assert_same stored, map[:key]
        assert_equal :local, map.mode
      end
    end

    def test_raise_mode_rejects_a_value_without_changing_the_mapping
      MAP_CLASSES.each do |klass|
        original = ModePayload.new(:original)
        map = klass.new({ key: original }, mode: :local)

        error = assert_raises(Ractor::IsolationError) do
          map.store(:key, ModePayload.new(:rejected), mode: :raise)
        end

        assert_match(/value is not Ractor-shareable/, error.message)
        assert_same original, map[:key]
      end
    end

    def test_store_if_absent_wraps_only_the_value_that_is_stored
      MAP_CLASSES.each do |klass|
        map = klass.new(mode: :local)
        value = ModePayload.new(:value)
        calls = 0

        assert_same(value, map.store_if_absent(:key) do
          calls += 1
          value
        end)
        assert_same(value, map.store_if_absent(:key, mode: :move) do
          calls += 1
          ModePayload.new(:ignored)
        end)
        assert_equal 1, calls
        assert_same value, map[:key]
      end
    end

    def test_compare_and_set_uses_logical_values_and_does_not_eagerly_move_replacements
      MAP_CLASSES.each do |klass|
        map = klass.new({ key: ModePayload.new(:expected) })
        failed_replacement = ModePayload.new(:failed)

        refute map.compare_and_set(:missing, nil, failed_replacement, mode: :move)
        refute map.key?(:missing)
        refute_operator Ractor::MovedObject, :===, failed_replacement
        refute map.compare_and_set(:key, ModePayload.new(:other), failed_replacement, mode: :move)
        refute_operator Ractor::MovedObject, :===, failed_replacement

        replacement = ModePayload.new(:replacement)

        assert map.compare_and_set(:key, ModePayload.new(:expected), replacement, mode: :local)
        assert_same replacement, map[:key]
      end
    end

    def test_compare_and_set_can_compare_values_by_identity
      MAP_CLASSES.each do |klass|
        original = ModePayload.new(:value)
        equal = ModePayload.new(:value)
        map = klass.new({ key: original }, mode: :local, compare_values_by_identity: true)

        refute map.compare_and_set(:key, equal, :nope)
        assert map.compare_and_set(:key, original, :replacement)
        assert_equal :replacement, map[:key]
      end
    end

    def test_update_receives_a_logical_value_and_releases_failed_reservations
      MAP_CLASSES.each do |klass|
        original = ModePayload.new(:original)
        map = klass.new({ key: original }, mode: :local)
        seen = nil

        result = map.update(:key, mode: :copy) do |current|
          seen = current
          ModePayload.new(:updated)
        end

        assert_same original, seen
        assert_equal :updated, result.value
        assert_same result, map[:key]

        assert_raises(Ractor::IsolationError) do
          map.update(:key, mode: :raise) { ModePayload.new(:rejected) }
        end

        assert_same result, map[:key]
        assert_equal :recovered, map.update(:key) { :recovered }
      end
    end

    def test_upsert_does_not_wrap_an_ignored_initial_value
      MAP_CLASSES.each do |klass|
        map = klass.new({ key: :current })
        ignored = ModePayload.new(:ignored)

        assert_equal :updated, map.upsert(:key, ignored, mode: :move) { :updated }
        refute_operator Ractor::MovedObject, :===, ignored
        assert_equal :ignored, ignored.value

        initial = ModePayload.new(:initial)
        stored = map.upsert(:missing, initial, mode: :local) { flunk "updated an absent key" }

        assert_same initial, stored
        assert_same initial, map[:missing]
      end
    end

    def test_upsert_updates_a_present_nil_instead_of_inserting_the_initial_value
      MAP_CLASSES.each do |klass|
        map = klass.new({ key: nil })
        seen = :unset

        result = map.upsert(:key, :initial) do |current|
          seen = current
          :updated
        end

        assert_nil seen
        assert_equal :updated, result
        assert_equal :updated, map[:key]
      end
    end

    def test_timeout_fallbacks_are_returned_without_unwrapping
      MAP_CLASSES.each do |klass|
        map = klass.new({ key: ModePayload.new(:current) }, mode: :local)
        current = map[:key]
        entered = Thread::Queue.new
        release = Thread::Queue.new
        updater = Thread.new do
          map.update(:key) do |current|
            entered << true
            release.pop
            current
          end
        end
        entered.pop
        fallback = Envelope.new(ModePayload.new(:fallback), mode: :local)
        managed_fallback = map.instance_variable_get(:@manager).wrap(ModePayload.new(:managed), mode: :local)

        assert_same fallback, map.get(:key, timeout: 0) { fallback }
        assert_same managed_fallback, map.store(:key, :new, timeout: 0) { managed_fallback }
        assert_same fallback, map.swap(:key, :new, timeout: 0) { fallback }
        assert_same managed_fallback,
          map.wait_until_changed(:key, current, timeout: 0) { managed_fallback }
      ensure
        release&.push(true)
        updater&.join
      end
    end

    def test_wait_until_changed_uses_logical_value_comparison
      MAP_CLASSES.each do |klass|
        map = klass.new({ key: ModePayload.new(:old) })

        assert_equal :timeout,
          map.wait_until_changed(:key, ModePayload.new(:old), timeout: 0) { :timeout }

        waiter = Thread.new { map.wait_until_changed(:key, ModePayload.new(:old), timeout: 1) }
        map.store(:key, ModePayload.new(:new))
        result = waiter.value

        assert_equal :new, result.value
      end
    end

    def test_copy_mode_transfers_values_between_ractors
      return unless Internal.native_ractors?

      MAP_CLASSES.each do |klass|
        source = ModePayload.new(:original)
        map = klass.new({ key: source })
        source.value = :changed
        worker = Ractor.new(map) do |shared|
          current = shared[:key]
          shared.update(:key) { |value| Helpers::ModePayload.new(:"#{value.value}-updated") }
          current.value
        end

        assert_equal :original, ractor_value(worker)
        assert_equal :"original-updated", map[:key].value
      end
    end

    def test_move_mode_allows_one_ractor_to_claim_a_value
      return unless Internal.native_ractors?

      MAP_CLASSES.each do |klass|
        source = ModePayload.new(:value)
        map = klass.new(mode: :move)

        map[:key] = source

        assert_operator Ractor::MovedObject, :===, source

        worker = Ractor.new(map) { |shared| shared[:key].value }

        assert_equal :value, ractor_value(worker)
        assert_raises(Envelope::AlreadyClaimed) { map[:key] }
      end
    end

    def test_move_mode_constructor_leaves_the_value_available_to_another_ractor
      return unless Internal.native_ractors?

      MAP_CLASSES.each do |klass|
        source = ModePayload.new(:value)
        map = klass.new({ key: source }, mode: :move)

        assert_operator Ractor::MovedObject, :===, source

        worker = Ractor.new(map) { |shared| shared[:key].value }

        assert_equal :value, ractor_value(worker)
        assert_raises(Envelope::AlreadyClaimed) { map[:key] }
      end
    end

    def test_local_mode_keeps_values_in_the_creating_ractor
      return unless Internal.native_ractors?

      MAP_CLASSES.each do |klass|
        source = ModePayload.new(:value)
        map = klass.new({ key: source }, mode: :local)
        worker = Ractor.new(map) do |shared|
          shared[:key]
          :opened
        rescue Farce::Envelope::AlreadyClaimed
          :rejected
        end

        assert_equal :rejected, ractor_value(worker)
        assert_same source, map[:key]
      end
    end

    def test_weak_key_map_collects_a_key_with_an_enveloped_value
      map, envelope = build_weak_key_entry

      assert_instance_of Envelope::Copy, envelope
      assert_eventually_empty(map)
    end

    def test_weak_key_waiter_survives_key_collection_and_reinsertion
      entered = Thread::Queue.new
      resume = Thread::Queue.new
      key_holder = []
      map = Thread.new do
        key_holder << shared_string("key")
        WeakKeyMap.new({ key_holder.first => ObservedWaitValue.new(entered, resume) }, mode: :local)
      end.value
      lookup_key = shared_string("key")
      waiter = Thread.new { map.wait_until_changed(lookup_key, :expected) }

      begin
        Timeout.timeout(5) { entered.pop }
        key_holder.clear
        # Clear the Vault's last canonical-key reply while comparison is paused.
        map[:missing]

        assert_eventually_empty(map)
        map[lookup_key] = :changed
        resume << true

        assert waiter.join(5), "waiter remained on an orphaned weak-key entry"
        assert_includes [nil, :changed], waiter.value
      ensure
        resume << true
        waiter.kill if waiter.alive?
        waiter.join
      end
    end

    def test_block_operations_require_a_block_before_wrapping_values
      MAP_CLASSES.each do |klass|
        map = klass.new

        assert_raises(LocalJumpError) { map.store_if_absent(:key) }
        assert_raises(LocalJumpError) { map.update(:key) }
        initial = ModePayload.new(:initial)

        assert_raises(LocalJumpError) { map.upsert(:key, initial, mode: :move) }
        refute_operator Ractor::MovedObject, :===, initial
      end
    end

    private

    def build_weak_key_entry
      # Build the key on a disposable native stack. CRuby conservatively scans
      # C stack slots, which can otherwise retain a stale reference to it.
      worker = Thread.new do
        map = WeakKeyMap.new
        key = Ractor.make_shareable(Object.new)
        value = ModePayload.new(:value)
        map[key] = value
        internal = map.instance_variable_get(:@map)
        envelope = internal[key]
        # The Vault read reply includes the canonical key. Replace that reply
        # with a missing-key read before GC can scan stale owner stack slots.
        internal[:missing]
        [map, envelope]
      end

      flunk "weak-key entry creation stalled:\n#{worker.backtrace&.join("\n")}" unless worker.join(5)

      worker.value
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def collect_garbage
      RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
    end

    def assert_eventually_empty(map)
      50.times do
        2_000.times { Object.new }
        collect_garbage
        return assert_equal(0, map.size) if map.size.zero? # rubocop:disable Style/ZeroLengthPredicate
        sleep 0.01
      end

      flunk "weak-key entry remained reachable after repeated collections"
    end
  end
end
