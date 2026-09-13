# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestMapPerKey < Test
      def test_native_memory_accounting_tracks_live_reservations
        return unless RUBY_ENGINE == "ruby"

        assert_native_memory_accounting_tracks_live_reservations
      end

      class BlockingHashKey
        def initialize(entered)
          @entered = entered
          @release = Thread::Queue.new
          @hash_calls = 0
        end

        def hash
          @hash_calls = @hash_calls.succ
          if @hash_calls == 2
            @entered << true
            @release.pop
          end
          0
        end

        def eql?(other) = other.is_a?(BlockingHashKey)
      end

      class BlockingEqualityControl
        def initialize(entered)
          @entered = entered
          @release = Thread::Queue.new
          @mutex = Mutex.new
          @used = false
        end

        def block_once
          should_block = @mutex.synchronize do
            next false if @used

            @used = true
          end
          return unless should_block

          @entered << true
          @release.pop
        end
      end

      class BlockingEqualityKey
        attr_reader :rank

        def initialize(rank, control)
          @rank = rank
          @control = control
        end

        def hash = 0

        def eql?(other)
          @control.block_once
          other.is_a?(BlockingEqualityKey) && rank == other.rank
        end
      end

      class ReenteringContendedKey
        attr_reader :rank

        def initialize(rank)
          @rank = rank
          @map = nil
        end

        def activate(map) = @map = map
        def hash = 0

        def eql?(other)
          @map&.update(:busy) { 9 }
          other.is_a?(ReenteringContendedKey) && rank == other.rank
        end
      end

      def test_different_keys_progress_while_one_key_is_reserved
        map = Map.new({ first: 1, second: 2 })
        entered = Thread::Queue.new
        release = Thread::Queue.new
        worker = Thread.new do
          map.update(:first) do |old|
            entered << true
            release.pop
            old + 1
          end
        end
        Timeout.timeout(5) { entered.pop }

        assert_equal 1, Timeout.timeout(1) { map[:first] }
        assert_equal :timeout, map.get(:first, timeout: 0) { :timeout }
        assert_equal 3, map.update(:second, timeout: 0) { |old| old + 1 }
        assert_equal 4, map.store(:third, 4, timeout: 0)
        assert_nil map.get(:missing, timeout: 0) { flunk "unrelated key blocked" }
      ensure
        release << true if release
        worker&.join(5) || worker&.kill
      end

      def test_same_key_updates_are_serialized
        map = Map.new({ key: 1 })
        first_entered = Thread::Queue.new
        release_first = Thread::Queue.new
        first = Thread.new do
          map.update(:key) do |old|
            first_entered << true
            release_first.pop
            old + 1
          end
        end
        Timeout.timeout(5) { first_entered.pop }
        second_started = Thread::Queue.new
        second = Thread.new do
          second_started << true
          map.update(:key) { |old| old + 1 }
        end
        Timeout.timeout(5) { second_started.pop }

        refute second.join(0.05), "same-key update did not wait"
        release_first << true

        assert first.join(5), "first update did not finish"
        assert second.join(5), "waiting update did not finish"
        assert_equal 2, first.value
        assert_equal 3, second.value
        assert_equal 3, map[:key]
      ensure
        release_first << true if release_first
        first&.kill if first&.alive?
        second&.kill if second&.alive?
      end

      def test_clear_invalidates_an_inflight_update
        map = Map.new({ key: 1 })
        entered = Thread::Queue.new
        release = Thread::Queue.new
        worker = Thread.new do
          map.update(:key) do |old|
            entered << true
            release.pop
            old + 1
          end
        end
        Timeout.timeout(5) { entered.pop }
        map.clear
        map[:key] = 9
        release << true

        assert worker.join(5), "invalidated update did not finish"
        assert_nil worker.value
        assert_equal 9, map[:key]
        assert_equal 1, map.size
      ensure
        release << true if release
        worker&.kill if worker&.alive?
      end

      def test_recursive_equal_key_access_raises_and_releases_the_reservation
        key = "key"
        equal_key = "key".dup.freeze
        map = Map.new({ key => 1 })

        assert_raises(ThreadError) do
          map.update(key) { map.update(equal_key) { 9 } }
        end

        assert_equal 2, map.update(equal_key, timeout: 0) { |old| old + 1 }
        assert_equal 2, map[key]
      end

      def test_timeout_does_not_leak_a_reservation
        map = Map.new({ key: 1 })
        entered = Thread::Queue.new
        release = Thread::Queue.new
        worker = Thread.new do
          map.update(:key) do |old|
            entered << true
            release.pop
            old + 1
          end
        end
        Timeout.timeout(5) { entered.pop }
        called = false

        assert_nil map.update(:key, timeout: 0) { called = true }
        refute called
        release << true

        assert worker.join(5), "owning update did not finish"
        assert_equal 2, worker.value
        assert_equal 3, map.update(:key, timeout: 0) { |old| old + 1 }
      ensure
        release << true if release
        worker&.kill if worker&.alive?
      end

      def test_thread_interruption_releases_the_reservation
        map = Map.new({ key: 1 })
        entered = Thread::Queue.new
        worker = Thread.new do
          map.update(:key) do
            entered << true
            Thread::Queue.new.pop
          end
        end
        Timeout.timeout(5) { entered.pop }
        worker.kill

        assert worker.join(5), "interrupted update did not finish"
        assert_equal 2, map.update(:key, timeout: 0) { |old| old + 1 }
        assert_equal 2, map[:key]
      ensure
        worker&.kill if worker&.alive?
      end

      def test_interrupted_key_callbacks_do_not_leak_a_reservation_checkout
        return if RUBY_ENGINE == "ruby"

        assert_interrupted_hash_checkout_cleanup
        assert_interrupted_equality_checkout_cleanup
      end

      def test_native_key_callback_reentry_is_rejected_before_waiting_on_another_key
        return if RUBY_ENGINE == "ruby"

        assert_native_key_callback_reentry_is_rejected
      end

      private

      def assert_native_memory_accounting_tracks_live_reservations
        require "objspace"

        map = Map.new({ key: 1 })
        baseline = ObjectSpace.memsize_of(map)
        entered = Thread::Queue.new
        release = Thread::Queue.new
        worker = Thread.new do
          map.update(:key) do |value|
            entered << true
            release.pop
            value + 1
          end
        end
        Timeout.timeout(5) { entered.pop }

        assert_operator ObjectSpace.memsize_of(map), :>, baseline
        map.clear

        assert_operator ObjectSpace.memsize_of(map), :>, baseline
        release << true

        assert worker.join(5), "canceled update did not finish"
        worker.value

        assert_equal baseline, ObjectSpace.memsize_of(map)
      ensure
        release << true if release
        worker&.kill if worker&.alive?
        worker&.join
      end

      def assert_native_key_callback_reentry_is_rejected
        stored = ReenteringContendedKey.new(1)
        probe = ReenteringContendedKey.new(2)
        map = Map.new({ stored => 1, busy: 1 })
        stored.activate(map)
        probe.activate(map)
        owner_entered = Thread::Queue.new
        release_owner = Thread::Queue.new
        owner = Thread.new do
          map.update(:busy) do |old|
            owner_entered << true
            release_owner.pop
            old + 1
          end
        end
        Timeout.timeout(5) { owner_entered.pop }
        operation = Thread.new do
          map[probe] = 2
        rescue ThreadError => e
          e
        end

        assert operation.join(2), "native key callback waited on another key"
        error = operation.value

        assert_kind_of ThreadError, error
        assert_match(/recursive map access during an operation/, error.message)
        release_owner << true

        assert owner.join(5), "reservation owner did not finish"
        assert_equal 2, owner.value
        assert_equal 3, map.update(:busy, timeout: 0) { |old| old + 1 }
      ensure
        release_owner << true if release_owner
        owner&.kill if owner&.alive?
        operation&.kill if operation&.alive?
      end

      def assert_interrupted_hash_checkout_cleanup
        entered = Thread::Queue.new
        key = BlockingHashKey.new(entered)
        map = Map.new
        worker = Thread.new { map.update(key) { 1 } }
        Timeout.timeout(5) { entered.pop }
        worker.kill

        assert worker.join(5), "interrupted hash callback did not finish"
        assert_equal 1, map.update(key, timeout: 0) { 1 }
      ensure
        worker&.kill if worker&.alive?
      end

      def assert_interrupted_equality_checkout_cleanup
        comparison_entered = Thread::Queue.new
        control = BlockingEqualityControl.new(comparison_entered)
        stored_key = BlockingEqualityKey.new(1, control)
        equal_key = BlockingEqualityKey.new(1, control)
        map = Map.new
        owner_entered = Thread::Queue.new
        release_owner = Thread::Queue.new
        owner = Thread.new do
          map.update(stored_key) do
            owner_entered << true
            release_owner.pop
            1
          end
        end
        Timeout.timeout(5) { owner_entered.pop }
        contender = Thread.new { map.update(equal_key) { 2 } }
        Timeout.timeout(5) { comparison_entered.pop }
        contender.kill

        assert contender.join(5), "interrupted equality callback did not finish"
        release_owner << true

        assert owner.join(5), "reservation owner did not finish"
        assert_equal 1, owner.value
        assert_equal 2, map.update(equal_key, timeout: 0) { |old| old + 1 }
      ensure
        release_owner << true if release_owner
        owner&.kill if owner&.alive?
        contender&.kill if contender&.alive?
      end
    end
  end
end
