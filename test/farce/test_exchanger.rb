# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestExchanger < Test
    include Helpers::InternalTestHelpers

    def test_public_types_and_shareability
      [Exchanger, Strict::Exchanger].each do |type|
        exchanger = type.new

        assert_equal Abstract::Exchanger, type.superclass
        refute_predicate exchanger, :frozen?
        assert_predicate exchanger, :ractor_shareable?
        assert Ractor.shareable?(exchanger)
      end
    end

    def test_pairing_and_reuse
      [Exchanger, Strict::Exchanger].each do |type|
        exchanger = type.new
        3.times do
          first, second = exchange_pair(exchanger, :first, :second)

          assert_equal :second, first
          assert_equal :first, second
        end
      end
    end

    def test_nil_and_false_are_successful_values
      [Exchanger, Strict::Exchanger].each do |type|
        first, second = exchange_pair(type.new, nil, false)

        assert_same false, first
        assert_nil second
      end
    end

    def test_timeout_fallback_and_recovery
      [Exchanger, Strict::Exchanger].each do |type|
        exchanger = type.new
        fallback = Object.new

        assert_nil exchanger.exchange(:expired, timeout: 0)
        assert_same fallback, exchanger.exchange(:expired, timeout: 0.01) { fallback }
        assert_raises(RuntimeError) { exchanger.exchange(:expired, timeout: 0) { raise "fallback" } }
        assert_equal %i[second first], exchange_pair(exchanger, :first, :second)
      end
    end

    def test_invalid_timeouts
      [Exchanger, Strict::Exchanger].each do |type|
        exchanger = type.new

        [-1, Float::INFINITY, Float::NAN].each do |timeout|
          assert_raises(ArgumentError) { exchanger.exchange(:value, timeout:) }
        end
      end
    end

    def test_ractor_exchange
      [Exchanger, Strict::Exchanger].each do |type|
        exchanger = type.new
        worker = Ractor.new(exchanger) { |shared| shared.exchange(:worker, timeout: 5) }

        assert_equal :worker, exchanger.exchange(:main, timeout: 5)
        assert_equal :main, ractor_value(worker)
      end
    end

    def test_scheduled_fibers_can_pair
      return unless Fiber.respond_to?(:set_scheduler)

      begin
        [Exchanger, Strict::Exchanger].each do |type|
          scheduler = Helpers::QueueTestScheduler.new
          Fiber.set_scheduler(scheduler)
          exchanger = type.new
          received = []
          Fiber.schedule { received << exchanger.exchange(:first, timeout: 1) }
          Fiber.schedule { received << exchanger.exchange(:second, timeout: 1) }
          Fiber.set_scheduler(nil)

          assert_equal %i[first second], received
          assert_operator scheduler.io_wait_calls, :>=, 1
        end
      ensure
        Fiber.set_scheduler(nil)
      end
    end

    def test_default_copy_mode_between_ractors
      exchanger = Exchanger.new
      original = [:main]
      worker = Ractor.new(exchanger) do |shared|
        received = shared.exchange([:worker], timeout: 5)
        received << :changed
      end

      assert_equal :copy, exchanger.mode
      assert_equal [:worker], exchanger.exchange(original, timeout: 5)
      assert_equal %i[main changed], ractor_value(worker)
      assert_equal [:main], original if Internal.native_ractors?
    end

    def test_default_and_per_call_transfer_modes
      exchanger = Exchanger.new(mode: :raise)
      original = [:payload]

      assert_equal :raise, exchanger.mode
      assert_raises(Ractor::IsolationError) { exchanger.exchange(Unshared::Queue.new, timeout: 0) }

      worker = Thread.new { exchanger.exchange(nil, timeout: 5) }

      assert_nil exchanger.exchange(original, mode: :make_shareable, timeout: 5)
      assert_same original, worker.value
      assert Ractor.shareable?(original)
      assert_raises(ArgumentError) { Exchanger.new(mode: :invalid) }
    end

    def test_local_mode_preserves_mutable_identity
      exchanger = Exchanger.new(mode: :local)
      original = []
      first, second = exchange_pair(exchanger, original, nil)

      assert_nil first
      assert_same original, second
      refute_predicate original, :frozen?
    end

    def test_move_mode_between_ractors
      return unless Internal.native_ractors?

      exchanger = Exchanger.new(mode: :move)
      original = [:payload]
      worker = Ractor.new(exchanger) { |shared| shared.exchange(nil, timeout: 5) }

      assert_nil exchanger.exchange(original, timeout: 5)
      assert_equal [:payload], ractor_value(worker)
      assert_raises(Ractor::MovedError) { original.size }
    end

    def test_timeout_does_not_undo_value_preparation
      return unless Internal.native_ractors?

      exchanger = Exchanger.new
      moved = []
      frozen = []

      assert_nil exchanger.exchange(moved, mode: :move, timeout: 0)
      assert_raises(Ractor::MovedError) { moved.size }
      assert_nil exchanger.exchange(frozen, mode: :make_shareable, timeout: 0)
      assert_predicate frozen, :frozen?
    end

    def test_envelopes_are_not_opened
      [Exchanger, Strict::Exchanger].each do |type|
        envelope = Envelope.new([:payload])
        first, second = exchange_pair(type.new, envelope, nil)

        assert_nil first
        assert_same envelope, second
      end
    end

    def test_strict_rejects_unshareable_values_and_modes
      exchanger = Strict::Exchanger.new

      refute_respond_to exchanger, :mode
      assert_raises(ArgumentError) { Strict::Exchanger.new(mode: :copy) }
      assert_raises(ArgumentError) { exchanger.exchange(:value, mode: :copy) }
      assert_raises(Ractor::IsolationError) { exchanger.exchange(Unshared::Queue.new, timeout: 0) }
      assert_raises(Ractor::IsolationError) { exchanger.exchange([], timeout: 0) } if Internal.native_ractors?

      assert_equal %i[second first], exchange_pair(exchanger, :first, :second)
    end

    private

    def exchange_pair(exchanger, first, second)
      threads = [first, second].map do |value|
        Thread.new { exchanger.exchange(value, timeout: 5) { raise "exchange timed out" } }
      end
      threads.map(&:value)
    ensure
      threads&.each { |thread| thread.kill.join }
    end
  end
end
