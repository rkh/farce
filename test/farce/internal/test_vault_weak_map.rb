# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "weakref"

return unless RUBY_ENGINE == "ruby"
return if Farce.const_defined?("Internal::NATIVE_WEAK_MAPS") && Farce.const_get("Internal::NATIVE_WEAK_MAPS")

module Farce
  module Internal
    class TestVaultWeakMap < Test
      include Helpers::InternalTestHelpers

      class CallerLocalValue
        def initialize(rank)
          @rank = rank
          @owner = Ractor.current
          freeze
        end

        def ==(other)
          raise "value comparison escaped its caller" unless Ractor.current.equal?(@owner)
          other.is_a?(CallerLocalValue) && @rank == other.rank
        end

        protected

        attr_reader :rank
      end

      class ReentrantKey
        def initialize(map)
          @map = map
          @active = Atom.new(false)
          freeze
        end

        def active=(value)
          @active.store(value)
        end

        def hash
          @map.size if @active.value
          0
        end
      end

      class PausingKey
        def initialize(entered, release)
          @entered = entered
          @release = release
          @armed = Atom.new(false)
          freeze
        end

        def arm = @armed.store(true)

        def hash
          if @armed.compare_and_set(true, false)
            @entered.push(:hashing)
            raise "test release timed out" unless @release.pop(timeout: 5)
          end
          0
        end
      end

      def map_classes = [WeakKeyMap, WeakValueMap, WeakMap]

      def test_key_callback_reentry_is_rejected_without_poisoning_the_vault
        map_classes.each do |klass|
          map = klass.new
          key = ReentrantKey.new(map)
          map[key] = 1
          begin
            key.active = true

            assert_raises(ThreadError) { map[key] }
          ensure
            key.active = false
          end

          assert_equal 1, map[key]
          assert_equal 2, map[:other] = 2
        end
      end

      def test_failed_block_releases_its_claim_without_rehashing_the_key
        map_classes.each do |klass|
          map = klass.new
          key = ReentrantKey.new(map)
          map[key] = 1
          begin
            error = assert_raises(RuntimeError) do
              map.update(key) do
                key.active = true
                raise "block failed"
              end
            end
          ensure
            key.active = false
          end

          assert_equal "block failed", error.message
          assert_equal 1, map.get(key, timeout: 0) { :still_claimed }
          assert_equal 2, map.update(key, timeout: 0) { |old| old + 1 }
        end
      end

      def test_interrupted_claim_does_not_poison_the_key_or_reply_channel
        map = WeakKeyMap.new
        entered = Queue.new
        release = Queue.new
        key = PausingKey.new(entered, release)
        map[key] = 1
        key.arm
        called = false
        worker = Thread.new do
          map.update(key) do
            called = true
            9
          end
        end
        begin
          assert_equal :hashing, entered.pop(timeout: 5)
          worker.kill
        ensure
          release.push(:resume)

          assert worker.join(5), "interrupted map request did not finish cleanup"
        end

        refute called
        assert_equal 1, map.get(key, timeout: 0) { :still_claimed }
        assert_equal 2, map.store(:other, 2, timeout: 0)
        assert_equal 3, map.update(key, timeout: 0) { |old| old + 2 }
      ensure
        worker&.kill if worker&.alive?
      end

      def test_update_can_access_another_key
        map_classes.each do |klass|
          map = klass.new({ key: 1 })

          assert_equal(2, map.update(:key) do |old|
            map[:other] = 9
            old + 1
          end)
          assert_equal 9, map[:other]
          assert_equal 2, map[:key]
        end
      end

      def test_same_key_recursion_raises_without_poisoning_the_entry
        map_classes.each do |klass|
          map = klass.new({ key: 1 })

          assert_raises(ThreadError) { map.update(:key) { map[:key] = 9 } }
          assert_equal 1, map[:key]
          assert_equal 2, map.update(:key, timeout: 0) { |old| old + 1 }
        end
      end

      def test_blocks_run_in_the_requesting_ractor_and_fiber
        map_classes.each do |klass|
          map = klass.new({ key: 1 })
          worker = Ractor.new(map) do |shared|
            local = []
            caller_ractor = Ractor.current
            caller_fiber = Fiber.current
            result = shared.update(:key) do |old|
              local << [Ractor.current.equal?(caller_ractor), Fiber.current.equal?(caller_fiber)]
              old + 1
            end
            [result, local]
          end

          assert_equal [2, [[true, true]]], ractor_value(worker)
          assert_equal 2, map[:key]
        end
      end

      def test_value_comparisons_run_in_the_requesting_ractor
        map_classes.each do |klass|
          map = klass.new
          worker = Ractor.new(map) do |shared|
            value = CallerLocalValue.new(1)
            equivalent = CallerLocalValue.new(1)
            shared[:key] = value
            timed_out = shared.wait_until_changed(:key, equivalent, timeout: 0) { :timeout }
            matched = shared.compare_and_set(:key, equivalent, :replacement)
            [timed_out, matched]
          end

          assert_equal [:timeout, true], ractor_value(worker)
          assert_equal :replacement, map[:key]
        end
      end

      def test_unrelated_keys_progress_while_another_ractor_updates
        map_classes.each do |klass|
          map = klass.new({ key: 1 })
          entered = Queue.new
          release = Queue.new
          worker = Ractor.new(map, entered, release) do |shared, ready, resume|
            shared.update(:key) do |old|
              ready.push(:entered)
              raise "test release timed out" unless resume.pop(timeout: 5)
              old + 1
            end
          end
          begin
            assert_equal :entered, entered.pop(timeout: 5)
            assert_equal :busy, map.get(:key, timeout: 0) { :busy }
            assert_equal 9, map.store(:other, 9, timeout: 0)
            assert_equal 10, map.update(:other, timeout: 0) { |old| old + 1 }
          ensure
            release.push(:resume)
            result = ractor_value(worker)
          end

          assert_equal 2, result
          assert_equal 10, map[:other]
        end
      end

      def test_clear_invalidates_an_update_already_running_in_another_ractor
        map_classes.each do |klass|
          map = klass.new({ key: 1 })
          entered = Queue.new
          release = Queue.new
          worker = Ractor.new(map, entered, release) do |shared, ready, resume|
            calls = 0
            shared.update(:key) do |old|
              calls += 1
              ready.push(:entered)
              raise "test release timed out" unless resume.pop(timeout: 5)
              old + 1
            end
            calls
          end
          begin
            assert_equal :entered, entered.pop(timeout: 5)
            assert_same map, map.clear
            assert_equal 9, map.store(:key, 9, timeout: 0)
          ensure
            release.push(:resume)
            calls = ractor_value(worker)
          end

          assert_equal 1, calls
          assert_equal 9, map[:key]
          assert_equal 1, map.size
        end
      end

      def test_failed_creation_releases_the_key_for_another_ractor
        map_classes.each do |klass|
          map = klass.new
          assert_raises(RuntimeError) { map.store_if_absent(:key) { raise "failed" } }
          refute map.key?(:key)
          worker = Ractor.new(map) { |shared| shared.store_if_absent(:key, timeout: 1) { 9 } }

          assert_equal 9, ractor_value(worker)
          assert_equal 9, map[:key]
        end
      end

      def test_simultaneous_creation_from_multiple_ractors_runs_one_block
        map_classes.each do |klass|
          map = klass.new
          ready = Queue.new
          start = Queue.new
          calls = Queue.new
          workers = 4.times.map do
            Ractor.new(map, ready, start, calls) do |shared, entered, release, invoked|
              entered.push(:ready)
              raise "test start timed out" unless release.pop(timeout: 5)
              shared.store_if_absent(:key) do
                invoked.push(:called)
                42
              end
            end
          end
          begin
            4.times { assert_equal :ready, ready.pop(timeout: 5) }
          ensure
            4.times { start.push(:start) }
          end
          results = workers.map { ractor_value(it) }

          assert_equal [42, 42, 42, 42], results
          assert_equal 1, calls.size
          assert_equal 1, map.size
        end
      end

      def test_vault_does_not_keep_an_abandoned_map_or_its_values_alive
        live_key = Object.new.freeze
        other_map = WeakKeyMap.new
        map_reference, value_reference = Thread.new do
          value = Object.new.freeze
          map = WeakKeyMap.new({ live_key => value })
          [WeakRef.new(map), WeakRef.new(value)]
        end.value

        40.times do
          # Give the owner another request so its last reply cannot keep the
          # abandoned map's value alive on a conservative native stack.
          other_map[:touch] = :value
          GC.start
          break unless map_reference.weakref_alive? || value_reference.weakref_alive?
          sleep 0.01
        end

        refute_predicate map_reference, :weakref_alive?, "Vault retained the abandoned map"
        refute_predicate value_reference, :weakref_alive?, "Vault retained an abandoned map's strong value"
        assert_predicate live_key, :frozen?
      end

      def test_map_can_be_created_in_a_non_main_ractor
        map_classes.each do |klass|
          worker = Ractor.new(klass) do |type|
            map = type.new({ key: 1 })
            map.update(:key) { |old| old + 1 }
            map
          end
          map = ractor_value(worker)

          assert Ractor.shareable?(map)
          assert_equal 2, map[:key]
          assert_equal 3, map.update(:key) { |old| old + 1 }
        end
      end
    end
  end
end
