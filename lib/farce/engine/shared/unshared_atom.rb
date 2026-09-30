# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedAtom
      TIMED_OUT = Object.new.freeze
      private_constant :TIMED_OUT

      def initialize(value = nil, compare_by_identity: false)
        if compare_by_identity != true && compare_by_identity != false
          raise ArgumentError, "compare_by_identity must be a boolean"
        end

        @value               = value
        @compare_by_identity = compare_by_identity
        @mutex               = Mutex.new
        @signal              = ConditionVariable.new
        @updating            = false
        @updating_fiber      = nil
        @updating_thread     = nil
        @version             = 0
        @farce_frozen        = false
      end

      # @api private
      def transaction_snapshot
        PortableTransaction.snapshot(self, :atom)
      end

      def value = @mutex.synchronize { @value }

      def freeze
        @mutex.synchronize { @farce_frozen = true }
        self
      end

      def frozen? = @mutex.synchronize { @farce_frozen }

      def get(timeout: nil, &fallback)
        result = with_available_value(timeout) { @value }
        timed_out(result, fallback)
      end

      def store(new_value, timeout: nil, &fallback)
        check_frozen!
        result = with_available_value(timeout) do
          check_frozen_locked!
          @value = new_value
          changed!
          new_value
        end
        timed_out(result, fallback)
      end

      def swap(new_value, timeout: nil, &fallback)
        check_frozen!
        result = with_available_value(timeout) do
          check_frozen_locked!
          old_value = @value
          @value = new_value
          changed!
          old_value
        end
        timed_out(result, fallback)
      end

      def store_if_absent(timeout: nil, &update)
        raise LocalJumpError, "no block given" unless update
        check_frozen!
        deadline = timeout_deadline(timeout)

        current = reserve(deadline) do
          return @value unless @value.nil?
        end
        return if TIMED_OUT.equal?(current)

        update_reserved(&update)
      end

      def compare_and_set(expected, new_value, timeout: nil)
        check_frozen!
        current = reserve(timeout_deadline(timeout))
        return false if TIMED_OUT.equal?(current)

        matched = false
        begin
          matches = values_equal?(current, expected)
          check_frozen!
          matched = matches
        ensure
          finish_update(new_value, changed: matched)
        end
        matched
      end

      def update(timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!
        deadline = timeout_deadline(timeout)

        current = reserve(deadline)
        return if TIMED_OUT.equal?(current)

        update_reserved { yield(current) }
      end

      def upsert(initial_value, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        check_frozen!
        deadline = timeout_deadline(timeout)

        current = reserve(deadline) do
          next unless @value.nil?

          @value = initial_value
          changed!
          return initial_value
        end
        return if TIMED_OUT.equal?(current)

        update_reserved { yield(current) }
      end

      def wait_until_changed(expected, timeout: nil, &fallback)
        deadline = timeout_deadline(timeout)

        loop do
          current, version = @mutex.synchronize { [@value, @version] }
          return current unless values_equal?(current, expected)

          result = @mutex.synchronize do
            next unless @version == version
            reject_update_wait! if @updating
            TIMED_OUT unless wait_for_signal(deadline)
          end
          return timed_out(result, fallback) if TIMED_OUT.equal?(result)
        end
      end

      def wait_until_non_nil(timeout: nil, &) = wait_until_changed(nil, timeout:, &)
      def compare_by_identity? = @compare_by_identity

      alias value= store

      private

      def with_available_value(timeout)
        deadline = timeout_deadline(timeout)

        @mutex.synchronize do
          while @updating
            reject_update_wait!
            return TIMED_OUT unless wait_for_signal(deadline)
          end
          yield
        end
      end

      def reserve(deadline)
        @mutex.synchronize do
          while @updating
            reject_update_wait!
            return TIMED_OUT unless wait_for_signal(deadline)
          end
          check_frozen_locked!
          yield if block_given?
          @updating        = true
          @updating_fiber  = Fiber.current
          @updating_thread = Thread.current
          @value
        end
      end

      def update_reserved
        changed = false
        begin
          result = yield
          check_frozen!
          changed = true
          result
        ensure
          finish_update(result, changed:)
        end
      end

      def finish_update(value, changed:)
        @mutex.synchronize do
          @value = value if changed
          @version += 1 if changed
          @updating        = false
          @updating_fiber  = nil
          @updating_thread = nil
          @signal.broadcast
        end
      end

      def changed!
        @version += 1
        @signal.broadcast
      end

      def check_frozen!
        @mutex.synchronize { check_frozen_locked! }
      end

      def check_frozen_locked!
        return unless @farce_frozen

        raise FrozenError.new("can't modify frozen #{self.class}", receiver: self)
      end

      def timeout_deadline(timeout)
        return unless timeout

        timeout = Float(timeout)
        raise ArgumentError, "timeout must be non-negative" if timeout.negative?
        raise ArgumentError, "timeout must be finite"       if timeout.infinite?
        raise ArgumentError, "timeout must be a number"     if timeout.nan?

        Clock.now + timeout
      end

      def wait_for_signal(deadline)
        return @signal.wait(@mutex) unless deadline

        remaining = deadline - Clock.now
        return false unless remaining.positive?

        @signal.wait(@mutex, remaining)
        true
      end

      def reject_update_wait!
        raise ThreadError, "deadlock; recursive atom access during an update" if @updating_fiber.equal?(Fiber.current)

        scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler)
        return unless @updating_thread.equal?(Thread.current) && !scheduler

        raise ThreadError, "deadlock; atom update is owned by another unscheduled fiber"
      end

      def timed_out(result, fallback)
        return result unless TIMED_OUT.equal?(result)
        fallback&.call
      end

      def values_equal?(left, right)
        return left == right unless compare_by_identity?
        left.equal?(right)
      end
    end
  end
end
