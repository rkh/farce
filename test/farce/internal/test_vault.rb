# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestVault < Test
      class PausedEquality
        def initialize(entered, release)
          @entered = entered
          @release = release
        end

        def ==(_other)
          @entered.push(true)
          @release.pop(timeout: 5)
          true
        end
      end

      class RecursiveEquality
        def initialize(vault)
          @vault = vault
        end

        def ==(_other) = @vault.copy_out(:other)
      end

      def test_recursive_request_raises_without_stopping_the_vault
        return unless Internal.native_ractors?
        vault = Vault.new
        key = Object.new.freeze
        vault.copy_in(key, RecursiveEquality.new(vault))

        error = assert_raises(ThreadError) do
          Timeout.timeout(5) { vault.same_value?(key, :other, right_stored: false) }
        end

        assert_match(/recursive access from the Vault/, error.message)
        vault.copy_in(key, :recovered)

        assert_equal :recovered, Timeout.timeout(5) { vault.copy_out(key) }
      end

      def test_concurrent_callers_receive_their_own_copy_and_move_replies
        return unless Internal.native_ractors?
        vault = Vault.new
        workers = 8.times.map do |index|
          Thread.new do
            key = Object.new.freeze
            vault.copy_in(key, [index])
            [vault.copy_out(key), vault.move_out(key)]
          end
        end
        workers.each_with_index do |worker, index|
          assert worker.join(5), "Vault caller did not finish"
          assert_equal [[index], [index]], worker.value
        end
      ensure
        workers&.each { |worker| worker.kill if worker.alive? }
        workers&.each(&:join)
      end

      def test_copy_and_move_replies_progress_between_weak_map_requests
        return unless Internal.native_ractors?
        Timeout.timeout(30) do
          200.times do |index|
            map = Farce::WeakKeyMap.new
            source = [index]
            copied = map.store(:key, source, mode: :copy)

            assert_equal [index], copied
            refute_same source, copied
            assert_equal [index], map.store(:key, [index], mode: :move)
          end
        end
      end

      def test_interrupted_request_does_not_poison_later_replies
        return unless Internal.native_ractors?
        vault = Vault.new
        key = Object.new.freeze
        other_key = Object.new.freeze
        entered = Queue.new
        release = Queue.new
        vault.copy_in(key, PausedEquality.new(entered, release))
        vault.copy_in(other_key, :expected)
        worker = Thread.new { vault.same_value?(key, :other, right_stored: false) }

        assert entered.pop(timeout: 5), "Vault comparison never started"
        worker.kill

        assert worker.join(5), "interrupted caller did not finish"
        release.push(true)

        assert_equal :expected, Timeout.timeout(5) { vault.copy_out(other_key) }
        vault.copy_in(other_key, :replacement)

        assert_equal :replacement, Timeout.timeout(5) { vault.copy_out(other_key) }
      ensure
        release&.push(true)
        worker&.kill if worker&.alive?
        worker&.join
      end
    end
  end
end
