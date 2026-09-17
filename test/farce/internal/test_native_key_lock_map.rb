# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"
require "objspace"
require "weakref"

module Farce
  module Internal
    class TestNativeKeyLockMap < Test
      include Helpers::InternalTestHelpers

      class Key
        attr_accessor :callback
        attr_reader :rank

        def initialize(rank)
          @rank = rank
        end

        def hash = 7

        def eql?(other)
          callback&.call
          other.is_a?(Key) && rank == other.rank
        end
      end

      class HashFailure
        def hash = raise "hash failed"
      end

      class SharedProbe < SharedKeyLockMap
        def size = synchronize(:probe) { 0 }
      end

      class PublicationReentry
        attr_reader :reinitialize_rejected, :access_rejected

        def initialize(target)
          @target = target
        end

        def freeze
          begin
            @target.__send__(:initialize)
          rescue RuntimeError
            @reinitialize_rejected = true
          end
          begin
            @target.synchronize(:key) { raise "unpublished operation entered" }
          rescue RuntimeError => e
            raise unless e.message == "uninitialized key lock map"
            @access_rejected = true
          end
          super
        end
      end

      def run(...) = Timeout.timeout(10) { super }

      def test_dispatch_preserves_custom_registries_and_helper_subclasses
        assert_instance_of UnsharedKeyLockMap, KeyLockMap.new(registry_class: Farce::Unshared::Map)
        [Farce::Map, Farce::Strict::Map, Farce::Unshared::Map].each do |registry_class|
          custom = Class.new(registry_class)

          assert_instance_of KeyLockMap, KeyLockMap.new(registry_class: custom)
        end
        assert_instance_of SharedKeyLockMap, KeyLockMap.new(registry_class: Farce::Strict::Map)
        assert_instance_of SharedKeyLockMap, KeyLockMap.new(registry_class: Farce::Map)
        subclass = Class.new(KeyLockMap)

        assert_instance_of subclass, subclass.new(registry_class: Farce::Unshared::Map)
      end

      def test_mutable_collision_keys_use_equality_or_identity_as_configured
        locks = UnsharedKeyLockMap.new
        first = Key.new(1)
        equal = Key.new(1)
        other = Key.new(2)
        value = []

        assert_same value, locks.synchronize(first) { value }
        refute_predicate first, :frozen?
        locks.synchronize(first) do
          assert_raises(ThreadError) { locks.synchronize(equal) { flunk "equal key entered" } }
          assert_equal :different, locks.synchronize(other) { :different }
        end
        locks = UnsharedKeyLockMap.new(compare_keys_by_identity: true)

        assert_equal :independent, locks.synchronize(first) { locks.synchronize(equal) { :independent } }
        assert_raises(ThreadError) { locks.synchronize(first) { locks.synchronize(first) { :recursive } } }
      end

      def test_hash_and_equality_exceptions_and_reentry_release_reservations
        locks = UnsharedKeyLockMap.new
        baseline = ObjectSpace.memsize_of(locks)
        first = Key.new(1)
        other = Key.new(2)

        assert_raises(RuntimeError) { locks.synchronize(HashFailure.new) { flunk "invalid hash entered" } }
        locks.synchronize(first) do
          first.callback = -> { raise "equality failed" }

          assert_raises(RuntimeError) { locks.synchronize(other) { flunk "invalid equality entered" } }
          first.callback = -> { locks.synchronize(:nested) { flunk "recursive equality entered" } }

          assert_raises(ThreadError) { locks.synchronize(other) { flunk "recursive comparison entered" } }
          first.callback = nil

          assert_equal :recovered, locks.synchronize(other) { :recovered }
        end
        assert_equal baseline, ObjectSpace.memsize_of(locks)
        assert_equal :after, locks.synchronize(other) { :after }
      end

      def test_validation_initialization_and_ractor_pinning
        %i[compare_by_identity compare_keys_by_identity compare_values_by_identity].each do |option|
          assert_raises(ArgumentError) { UnsharedKeyLockMap.new(**{ option => :invalid }) }
        end
        assert_raises(ArgumentError) { UnsharedKeyLockMap.new(unknown: true) }
        raw = UnsharedKeyLockMap.allocate

        assert_raises(RuntimeError) { raw.synchronize(:key) { :invalid } }
        raw.__send__(:initialize)

        assert_raises(RuntimeError) { raw.__send__(:initialize) }
        assert_raises(TypeError) { raw.dup }
        assert_raises(TypeError) { raw.clone }
        assert_raises(NoMethodError) { raw.freeze }
        refute Ractor.shareable?(raw)
        assert_raises(Ractor::Error) { Ractor.make_shareable(raw) }
        worker = Ractor.new { Ractor.receive }

        assert_raises(TypeError, Ractor::Error) { worker.send(raw, move: true) }
        worker.send(:done)

        assert_equal :done, ractor_value(worker)
        assert_equal :usable, raw.synchronize(:key) { :usable }
      end

      def test_distinct_key_churn_retains_no_keys_or_reservation_memory
        locks = UnsharedKeyLockMap.new
        baseline = ObjectSpace.memsize_of(locks)
        references = Thread.new do
          sampled = []
          20_000.times do |index|
            key = Key.new(index)
            sampled << WeakRef.new(key) if (index % 100).zero?
            locks.synchronize(key) { nil }
          end
          sampled
        end.value
        2.times { GC.start(full_mark: true, immediate_sweep: true) }

        assert_equal baseline, ObjectSpace.memsize_of(locks)
        assert references.none?(&:weakref_alive?), "completed keys remained reachable"
      end

      def test_active_memory_tracks_concurrency_and_gc_compaction_preserves_keys
        locks = UnsharedKeyLockMap.new
        baseline = ObjectSpace.memsize_of(locks)
        sizes = []
        keys = 8.times.map { Key.new(it) }
        hold = lambda do |index|
          if index == keys.length
            GC.verify_compaction_references(double_heap: true, toward: :empty)
            assert_raises(ThreadError) { locks.synchronize(Key.new(3)) { flunk "active key lost" } }
          else
            locks.synchronize(keys[index]) do
              sizes << ObjectSpace.memsize_of(locks)
              hold.call(index + 1)
            end
          end
        end
        hold.call(0)
        increments = [baseline, *sizes].each_cons(2).map { |left, right| right - left }

        assert_operator increments.first, :>, 0
        assert_equal [increments.first], increments.uniq
        assert_equal baseline, ObjectSpace.memsize_of(locks)
      end

      def test_shared_keys_are_validated_without_transferring_block_results
        locks = SharedKeyLockMap.new
        called = false

        assert Ractor.shareable?(locks)
        assert_predicate locks, :frozen?
        assert_raises(Ractor::IsolationError) { locks.synchronize([]) { called = true } }
        refute called
        worker = Ractor.new(locks) do |shared|
          local = []
          result = shared.synchronize(:key) { local }
          result << :mutable
          [local.equal?(result), Ractor.shareable?(local), local.length]
        end

        assert_equal [true, false, 1], ractor_value(worker)
        assert_raises(TypeError) { locks.dup }
        assert_raises(TypeError) { locks.clone }
        assert_raises(RuntimeError) { locks.__send__(:initialize) }
      end

      def test_shared_publication_reentry_and_failure_leave_safe_state
        locks = SharedKeyLockMap.allocate
        metadata = PublicationReentry.new(locks)
        locks.instance_variable_set(:@metadata, metadata)

        assert_raises(RuntimeError) { locks.synchronize(:key) { flunk "uninitialized operation entered" } }
        locks.__send__(:initialize)

        assert metadata.reinitialize_rejected
        assert metadata.access_rejected
        assert Ractor.shareable?(locks)
        assert_equal :ready, locks.synchronize(:key) { :ready }
        failed = SharedKeyLockMap.allocate
        failed.instance_variable_set(:@thread, Thread.current)

        assert_raises(Ractor::Error) { failed.__send__(:initialize) }
        refute Ractor.shareable?(failed)
        assert_raises(RuntimeError) { failed.synchronize(:key) { flunk "failed publication entered" } }
      end

      def test_shared_concurrent_initializers_commit_once
        locks = SharedKeyLockMap.allocate
        start = ::Queue.new
        workers = 2.times.map do
          Thread.new do
            start.pop
            locks.__send__(:initialize)
            :initialized
          rescue RuntimeError
            :rejected
          end
        end
        2.times { start << true }

        assert_equal %i[initialized rejected], workers.map(&:value).sort
        assert Ractor.shareable?(locks)
        assert_equal :ready, locks.synchronize(:key) { :ready }
      end

      def test_shared_publication_is_visible_atomically_to_other_ractors
        assert_atomic_ractor_publication(SharedProbe, iterations: 200) { it.__send__(:initialize) }
      end

      def test_shared_distinct_key_churn_reclaims_keys_and_has_no_slot_table
        locks = SharedKeyLockMap.new
        baseline = ObjectSpace.memsize_of(locks)
        references = Thread.new do
          sampled = []
          20_000.times do |index|
            key = Key.new(index).freeze
            sampled << WeakRef.new(key) if (index % 100).zero?
            locks.synchronize(key) { nil }
          end
          sampled
        end.value
        2.times { GC.start(full_mark: true, immediate_sweep: true) }

        assert_equal baseline, ObjectSpace.memsize_of(locks)
        assert references.none?(&:weakref_alive?), "completed shared keys remained reachable"
        assert_equal ObjectSpace.memsize_of(SharedKeyLockMap.allocate), baseline
      end

      def test_canceling_a_waiter_preserves_owner_and_other_waiters
        locks = UnsharedKeyLockMap.new
        baseline = ObjectSpace.memsize_of(locks)
        entered = ::Queue.new
        release = ::Queue.new
        owner = Thread.new do
          locks.synchronize(:key) do
            entered << true
            release.pop
          end
        end
        entered.pop
        waiter = Thread.new { locks.synchronize(:key) { flunk "canceled waiter entered" } }

        refute waiter.join(0.01)
        waiter.kill.join
        survivor = Thread.new { locks.synchronize(:key) { :survived } }

        refute survivor.join(0.01)
        release << true
        owner.value

        assert_equal :survived, survivor.value
        assert_equal baseline, ObjectSpace.memsize_of(locks)
      ensure
        [owner, waiter, survivor].compact.each { it.kill.join if it.alive? }
      end
    end
  end
end
