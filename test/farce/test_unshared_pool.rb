# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_pool"

module Farce
  class TestUnsharedPool < TestPool
    include Helpers::InternalTestHelpers

    def test_schedule_uses_default_transfer_rules
      pool = pool_class.new(max_size: 1, shrink_after: nil)
      results = Unshared::Queue.new
      source = Unshared::Map.new
      caller = self
      caller_thread = Thread.current
      caller_ractor = Ractor.current
      pool.schedule(source) do |value|
        results << [value, self, Thread.current, Ractor.current, Fiber.respond_to?(:scheduler) && Fiber.scheduler]
      end
      value, receiver, thread, ractor, scheduler = results.pop(timeout: 2)

      assert_same source, value
      assert_same caller, receiver
      refute_same caller_thread, thread
      assert_same caller_ractor, ractor
      assert scheduler if Fiber.respond_to?(:set_scheduler)

      assert_predicate pool, :local?
      assert pool.local?(wait: false)
    ensure
      close_pool(pool)
    end

    def test_explicit_local_transfer_follows_pool_locality
      pool = pool_class.new(max_size: 1, shrink_after: nil)
      results = Unshared::Queue.new
      source = []
      pool.schedule(source, mode: :local, auto_local: false) { |value| results << value }

      assert_same source, results.pop(timeout: 2)
    ensure
      close_pool(pool)
    end

    def test_automatic_local_transfer_overrides_the_mode
      pool = pool_class.new(max_size: 1, shrink_after: nil)
      source = []
      results = Unshared::Queue.new
      %i[schedule try_schedule].each do |submission|
        [*Farce::MODES, :unknown, nil].each do |mode|
          pool.public_send(submission, source, mode:) { |value| results << value }

          assert_same source, results.pop(timeout: 2)
          assert_same(pool, pool.execute(source, mode:) { |value| assert_same source, value })
        end
      end

      refute_predicate source, :frozen?
    ensure
      close_pool(pool)
    end

    def test_disabled_auto_local_accepts_only_local_and_smart_modes
      pool = pool_class.new(max_size: 1, shrink_after: nil)
      results = Unshared::Queue.new
      source = Unshared::Map.new
      accepted = %i[local smart smart_raise smart_move smart_copy]
      accepted.each do |mode|
        %i[schedule try_schedule].each do |submission|
          pool.public_send(submission, source, mode:, auto_local: false) { |value| results << [value, self] }
          value, receiver = results.pop(timeout: 2)

          assert_same source, value
          assert_same self, receiver
        end
        assert_same(pool, pool.execute(source, mode:, auto_local: false) { |arg| assert_same source, arg })
      end
      (Farce::MODES.to_a - accepted + [:unknown, nil]).each do |mode|
        %i[schedule try_schedule].each do |submission|
          assert_raises(ArgumentError) { pool.public_send(submission, source, mode:, auto_local: false) { nil } }
        end
        assert_raises(ArgumentError) { pool.execute(source, mode:, auto_local: false) { nil } }
      end

      assert_instance_of Internal::UnsharedQueue, pool_queue(pool)
      refute_predicate source, :frozen?
    ensure
      close_pool(pool)
    end

    def test_execute_keeps_local_binding_and_returns_self
      pool = pool_class.new
      results = []
      fiber = Fiber.current

      assert_same(pool, pool.execute { results << [self, Fiber.current] })
      assert_equal [[self, fiber]], results
      assert_equal 0, pool.size
      pool.close
      assert_raises(SchedulerClosedError) { pool.execute { flunk "executed after close" } }
    ensure
      close_pool(pool)
    end

    def test_execute_is_local_with_automatic_local_transfer_disabled
      pool = pool_class.new
      results = []
      fiber = Fiber.current

      assert_same(pool, pool.execute(auto_local: false) { results << [self, Fiber.current] })
      assert_equal [[self, fiber]], results
      assert_equal 0, pool.size
    ensure
      close_pool(pool)
    end

    def test_missing_block_is_rejected
      pool = pool_class.new

      assert_raises(LocalJumpError) { pool.schedule }
      assert_equal 0, pool.size
    ensure
      close_pool(pool)
    end

    def test_pool_cannot_be_copied_or_marshaled
      pool = pool_class.new

      assert_raises(TypeError) { pool.dup }
      assert_raises(TypeError) { pool.clone }
      assert_raises(TypeError) { Marshal.dump(pool) }
    ensure
      close_pool(pool)
    end

    def test_ractor_transfer_contract
      return unless Internal.native_ractors?
      pool = pool_class.new

      assert_raises(Ractor::Error) { Ractor.make_shareable(pool) }
      assert_raises(TypeError, Ractor::Error) { Ractor.new(pool) { nil } }
      receiver = Ractor.new { Ractor.receive }
      assert_raises(TypeError, Ractor::Error) { receiver.send(pool, move: true) }
      receiver.send(:done)

      assert_equal :done, ractor_value(receiver)
      assert_predicate pool, :local?
    ensure
      close_pool(pool)
    end

    def test_scheduler_constructor_respects_ractor_boundary
      return unless Fiber.respond_to?(:set_scheduler)
      constructors = Unshared::Queue.new
      pool = pool_class.new(min_size: 1, max_size: 1, shrink_after: nil) do
        constructors << Thread.current
        Helpers::Internal::FiberScheduler.new
      end

      refute_same Thread.current, constructors.pop(timeout: 2)
      assert_nil pool.error
    ensure
      close_pool(pool)
    end

    private

    def pool_class = Unshared::Pool
  end
end
