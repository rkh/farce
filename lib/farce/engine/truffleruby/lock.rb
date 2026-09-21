# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # TruffleRuby parks forever when an unscheduled Fiber attempts to lock
    # a Mutex owned by another Fiber on the same native thread. MRI and JRuby
    # reject that cooperative deadlock with ThreadError. The atomic holder
    # remains mutable after Farce::Shareable freezes the public subclass.
    class Lock < Mutex
      include Freeze::Unfreezable

      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      private_constant :BASIC_OBJECT_EQUAL_METHOD

      def initialize
        @farce_owner_thread = TruffleRuby::AtomicReference.new(nil)
        super
      end

      def lock
        check_unscheduled_fiber_deadlock
        previously_owned = owned?
        completed = false

        begin
          # Keep the potentially unbounded native wait interruptible. If an
          # exception lands after Mutex#lock acquires but before this method
          # returns, the outer ensure detects ownership and rolls it back.
          result = super
          result = Thread.handle_interrupt(INTERRUPT_MASK) do
            @farce_owner_thread.set(Thread.current)
            result
          end
          completed = true
          result
        ensure
          release_incomplete_acquisition if !completed && !previously_owned && owned?
        end
      end

      def try_lock
        acquired = false
        completed = false

        begin
          result = Thread.handle_interrupt(INTERRUPT_MASK) do
            acquired = super
            @farce_owner_thread.set(Thread.current) if acquired
            acquired
          end
          completed = true
          result
        ensure
          release_incomplete_acquisition if acquired && !completed
        end
      end

      def unlock
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @farce_owner_thread.set(nil) if owned?
          super
        end
      end

      def synchronize
        return super unless block_given?

        check_unscheduled_fiber_deadlock
        super do
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @farce_owner_thread.set(Thread.current)
          end
          yield
        ensure
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @farce_owner_thread.set(nil) if owned?
          end
        end
      end

      def sleep(...)
        return super unless owned?

        Thread.handle_interrupt(INTERRUPT_MASK) do
          @farce_owner_thread.set(nil)
          begin
            Thread.handle_interrupt(Exception => :on_blocking) { super }
          ensure
            @farce_owner_thread.set(Thread.current) if owned?
          end
        end
      end

      private

      def initialize_copy(other)
        super
        @farce_owner_thread = TruffleRuby::AtomicReference.new(nil)
      end

      def check_unscheduled_fiber_deadlock
        owner_thread = @farce_owner_thread.get
        scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        same_thread = BASIC_OBJECT_EQUAL_METHOD.bind_call(owner_thread, Thread.current)
        return unless locked? && !owned? && same_thread && !scheduler

        raise ThreadError, "deadlock; lock already owned by another fiber on the same thread"
      end

      def release_incomplete_acquisition
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @farce_owner_thread.set(nil)
          Mutex.instance_method(:unlock).bind_call(self)
        end
      end
    end
  end
end
