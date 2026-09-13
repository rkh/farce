# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinates an update block for one logical map key.
    class MapKeyReservation
      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      INTERRUPT_MASK            = { Exception => :never }.freeze
      private_constant :BASIC_OBJECT_EQUAL_METHOD, :INTERRUPT_MASK

      def initialize
        @mutex        = Mutex.new
        @signal       = nil
        @reserved     = false
        @invalidated  = false
        @owner_fiber  = nil
        @owner_thread = nil
        @users        = 0
      end

      attr_accessor :users

      def reserve(deadline)
        while true
          signal, observed = @mutex.synchronize do
            return :invalidated if @invalidated
            unless @reserved
              Thread.handle_interrupt(INTERRUPT_MASK) do
                @reserved     = true
                @owner_fiber  = Fiber.current
                @owner_thread = Thread.current
                yield if block_given?
              end
              return :acquired
            end
            reject_recursive_wait!
            @signal ||= Signal.new
            [@signal, @signal.generation]
          end
          timeout = deadline - Clock.now if deadline
          return :timed_out if timeout && !timeout.positive?
          return :timed_out unless signal.wait(observed, timeout:) { false }
        end
      end

      def commit
        @mutex.synchronize do
          return false if @invalidated
          yield
          true
        end
      end

      def invalidate
        signal = @mutex.synchronize do
          @invalidated = true
          @signal
        end
        signal&.broadcast
      end

      def release
        signal = @mutex.synchronize do
          @reserved = false
          @owner_fiber = @owner_thread = nil
          @signal
        end
        signal&.broadcast
      end

      private

      def reject_recursive_wait!
        if BASIC_OBJECT_EQUAL_METHOD.bind_call(@owner_fiber, Fiber.current)
          raise ThreadError, "deadlock; recursive map access during an update"
        end
        scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        owner_thread = BASIC_OBJECT_EQUAL_METHOD.bind_call(@owner_thread, Thread.current)
        return unless owner_thread && !scheduler

        raise ThreadError, "deadlock; map update is owned by another unscheduled fiber"
      end
    end
    private_constant :MapKeyReservation

    module MapKeyCoordination
      BASIC_OBJECT_EQUAL_METHOD = BasicObject.instance_method(:equal?)
      INTERRUPT_MASK = { Exception => :never }.freeze
      private_constant :BASIC_OBJECT_EQUAL_METHOD, :INTERRUPT_MASK

      def initialize_key_coordination
        @reservation_mutex        = Mutex.new
        @reservation_clear_mutex  = Mutex.new
        @reservation_signal       = Signal.new
        @reservations             = {}
        @reservation_owner_fiber  = nil
        @reservation_owner_thread = nil
        @clearing_reservations    = false
      end

      def with_key_operation(key, deadline)
        @state_mutex.synchronize { reject_active_operation_reentry! }
        while true
          result = checkout_reservation(key, deadline) do |reservation|
            acquired = false
            begin
              Thread.handle_interrupt(Exception => :immediate) do
                status = reservation.reserve(deadline) { acquired = true }
                next status unless status == :acquired
                [:completed, yield(reservation)]
              end
            ensure
              reservation.release if acquired
              checkin_reservation(key, reservation)
            end
          end
          next if result == :invalidated
          return [false, nil] if result == :timed_out
          return [true, result.last]
        end
      end

      def clear_key_operations
        @reservation_clear_mutex.synchronize do
          Thread.handle_interrupt(INTERRUPT_MASK) do
            reservations = with_reservation_index do
              @clearing_reservations = true
              entries = @reservations.values
              @reservations = {}
              entries
            end
            begin
              reservations.each(&:invalidate)
              yield
            ensure
              reservations.each(&:invalidate)
              with_reservation_index { @clearing_reservations = false }
              @reservation_signal.broadcast
            end
          end
        end
      end

      private

      def checkout_reservation(key, deadline)
        while true
          generation  = @reservation_signal.generation
          reservation = nil
          result      = Thread.handle_interrupt(INTERRUPT_MASK) do
            reservation = with_reservation_index do
              next if @clearing_reservations

              rollback        = nil
              lookup_complete = false

              begin
                Thread.handle_interrupt(Exception => :immediate) do
                  reservation = @reservations[key]
                  unless reservation
                    reservation = MapKeyReservation.new
                    rollback = reservation
                    @reservations[key] = reservation
                  end
                end
                lookup_complete = true
              ensure
                Thread.handle_interrupt(INTERRUPT_MASK) do
                  if rollback && !lookup_complete
                    @reservations.delete_if do |_stored_key, current|
                      BASIC_OBJECT_EQUAL_METHOD.bind_call(current, rollback) && current.users.zero?
                    end
                  end
                end
              end
              reservation.users += 1
              reservation
            end
            yield(reservation) if reservation
          end
          return result if result

          timeout = deadline - Clock.now if deadline
          return :timed_out if timeout && !timeout.positive?
          return :timed_out unless @reservation_signal.wait(generation, timeout:) { false }
        end
      end

      def checkin_reservation(_key, reservation)
        with_reservation_index do
          reservation.users -= 1
          next unless reservation.users.zero?

          @reservations.delete_if do |_stored_key, current|
            BASIC_OBJECT_EQUAL_METHOD.bind_call(current, reservation)
          end
        end
      end

      def with_reservation_index
        reject_reservation_index_reentry!
        Thread.handle_interrupt(Exception => :on_blocking) do
          @reservation_mutex.synchronize do
            Thread.handle_interrupt(INTERRUPT_MASK) do
              @reservation_owner_fiber  = Fiber.current
              @reservation_owner_thread = Thread.current
              yield
            ensure
              @reservation_owner_fiber = @reservation_owner_thread = nil
            end
          end
        end
      end

      def reject_reservation_index_reentry!
        if BASIC_OBJECT_EQUAL_METHOD.bind_call(@reservation_owner_fiber, Fiber.current)
          raise ThreadError, "recursive map access from key equality"
        end
        scheduler    = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        owner_thread = BASIC_OBJECT_EQUAL_METHOD.bind_call(@reservation_owner_thread, Thread.current)
        return unless owner_thread && !scheduler

        raise ThreadError, "deadlock; map key equality is owned by another unscheduled fiber"
      end
    end
    private_constant :MapKeyCoordination
  end
end
