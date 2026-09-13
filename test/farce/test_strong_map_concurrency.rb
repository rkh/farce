# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestStrongMapConcurrency < Test
    include Helpers::InternalTestHelpers

    class PausedEquality
      include Shareable

      def initialize(entered, release)
        @entered = entered
        @release = release
        super()
      end

      def ==(_other)
        @entered.push(true)
        @release.pop(timeout: 5)
        true
      end
    end

    def test_clear_cancels_compare_and_set_without_reporting_success
      [Map, Strict::Map, Unshared::Map].each do |klass|
        entered = Internal::Queue.new
        release = Internal::Queue.new
        map = klass.new({ key: PausedEquality.new(entered, release) })
        worker = Thread.new { map.compare_and_set(:key, :expected, :replacement) }

        begin
          assert entered.pop(timeout: 5), "comparison never started"
          map.clear
          map[:key] = :new_entry
          release.push(true)

          assert worker.join(5), "comparison failed to finish"
          refute worker.value
          assert_equal :new_entry, map[:key]
        ensure
          release.push(true)
          worker.kill if worker.alive?
          worker.join
        end
      end
    end

    def test_copy_mode_updates_allow_other_keys_to_progress
      map = Map.new({ busy: ModePayload.new(:initial), free: ModePayload.new(:initial) })
      entered = Thread::Queue.new
      release = Thread::Queue.new
      worker = Thread.new do
        map.update(:busy) do |current|
          entered << current.value
          release.pop
          ModePayload.new(:updated)
        end
      end

      assert_equal :initial, Timeout.timeout(5) { entered.pop }
      assert_equal :initial, map[:busy].value
      assert_equal :timeout, map.get(:busy, timeout: 0) { :timeout }
      result = map.update(:free, timeout: 0) { ModePayload.new(:independent) }

      assert_equal :independent, result.value
      assert_equal :independent, map[:free].value
      release << true

      assert worker.join(5), "update failed to finish"
      assert_equal :updated, worker.value.value
      assert_equal :updated, map[:busy].value
    ensure
      release << true if release
      worker&.kill if worker&.alive?
      worker&.join
    end

    def test_different_keys_can_be_updated_from_different_ractors
      return unless Internal.native_ractors?

      [Map, Strict::Map].each do |klass|
        map = klass.new({ busy: 1, free: 2 })
        entered = Internal::Queue.new
        release = Internal::Queue.new
        worker = Ractor.new(map, entered, release) do |shared, started, continue_update|
          shared.update(:busy) do |old|
            started.push(true)
            continue_update.pop(timeout: 5)
            old + 1
          end
        end

        begin
          assert entered.pop(timeout: 5), "update never started"
          assert_equal 1, map[:busy]
          assert_equal :timeout, map.get(:busy, timeout: 0) { :timeout }
          assert_equal 3, map.update(:free, timeout: 0) { |old| old + 1 }
          assert_equal 4, map.store_if_absent(:new, timeout: 0) { 4 }
        ensure
          release.push(true)

          assert_equal 2, ractor_value(worker)
        end

        assert_equal 2, map[:busy]
        assert_equal 3, map[:free]
      end
    end
  end
end
