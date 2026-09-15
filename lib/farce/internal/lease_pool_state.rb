# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinates capacity, ownership, waiting, and cleanup for a resource pool.
    class LeasePoolState
      INTERRUPT_MASK = { Exception => :never }.freeze
      OWNERSHIP      = Object.new.freeze
      private_constant :INTERRUPT_MASK, :OWNERSHIP

      attr_reader :max_size

      def initialize(max_size)
        @max_size    = max_size
        @slots       = ::Farce::Counter.new
        @managed     = Counter.new
        @creating    = Counter.new
        @checked_out = Counter.new
        @available   = Queue.new(capacity: max_size)
        @signal      = Signal.new
        initialize_storage
        finalize_initialization
      end

      def size              = @managed.value
      def available_count   = @available.size
      def checked_out_count = @checked_out.value
      def creating_count    = @creating.value

      def checkout(factory, timeout: nil, &block)
        return checkout_block(factory, timeout, block) if block

        checkout_explicit(factory, timeout:, wait: true)
      end

      def try_checkout(factory, &block)
        return checkout_block(factory, nil, block, wait: false) if block

        checkout_explicit(factory, wait: false)
      end

      def checkin(resource)
        tokens = explicit_tokens(create: false)
        raise OwnershipError, "the current Fiber does not own an explicit pool checkout" unless tokens&.any?
        validate_resource!(resource) unless nil.equal?(resource)

        Thread.handle_interrupt(INTERRUPT_MASK) do
          token = tokens.last
          if nil.equal?(resource)
            @checked_out.decrement
            @managed.decrement
            @slots.decrement
          else
            return_resource(token, resource)
            @available.push(token)
            @checked_out.decrement
          end
          tokens.pop
          clear_explicit_tokens if tokens.empty?
          @signal.broadcast
        end
        self
      end

      private

      def checkout_explicit(factory, wait:, timeout: nil)
        acquisition = nil
        owned       = false
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            acquisition = acquire(factory, timeout:, wait:)
            return unless acquisition

            explicit_tokens << acquisition.first
            owned = true
          end
          acquisition.last
        rescue Exception # rubocop:disable Lint/RescueException
          rollback_explicit(acquisition) if owned
          raise
        end
      end

      def checkout_block(factory, timeout, block, wait: true)
        acquisition = nil
        Thread.handle_interrupt(INTERRUPT_MASK) do
          acquisition = acquire(factory, timeout:, wait:)
          return unless acquisition

          begin
            Thread.handle_interrupt(Exception => :immediate) { return block.call(acquisition.last) }
          ensure
            checkin_block(acquisition)
          end
        end
      end

      def acquire(factory, timeout:, wait:)
        deadline = timeout_deadline(timeout)

        loop do
          observed = @signal.generation
          token    = @available.try_pop
          return take_available(token) if token
          return create_resource(factory) if reserve_creation
          return unless wait

          remaining = deadline - Clock.now if deadline
          raise TimeoutError, "lease pool checkout timed out" if remaining && !remaining.positive?
          interval = LeaseWaiting.wait_interval(remaining)
          changed  = Thread.handle_interrupt(Exception => :immediate) do
            @signal.wait(observed, timeout: interval)
          end
          next if changed || interval != remaining

          raise TimeoutError, "lease pool checkout timed out"
        end
      end

      def take_available(token)
        resource = take_resource(token)
        @checked_out.increment
        [token, resource]
      rescue Exception # rubocop:disable Lint/RescueException
        @available.push(token)
        @signal.broadcast
        raise
      end

      def reserve_creation # rubocop:disable Naming/PredicateMethod
        return false unless @slots.increment_if_below(max_size)

        @creating.increment
        true
      end

      def create_resource(factory)
        committed = false
        stored    = false
        token     = nil
        begin
          resource = Thread.handle_interrupt(Exception => :immediate) { factory.call }
          validate_resource!(resource)
          token = next_token
          store_resource(token, resource)
          stored   = true
          resource = take_resource(token)
          stored   = false
          @managed.increment
          @creating.decrement
          @checked_out.increment
          committed = true
          [token, resource]
        ensure
          unless committed
            discard_resource(token) if stored
            @creating.decrement
            @slots.decrement
            @signal.broadcast
          end
        end
      end

      def checkin_block(acquisition)
        token, resource = acquisition
        return_resource(token, resource)
        @available.push(token)
        @checked_out.decrement
        @signal.broadcast
      end

      def rollback_explicit(acquisition)
        Thread.handle_interrupt(INTERRUPT_MASK) do
          token, resource = acquisition
          return_resource(token, resource)
          @available.push(token)
          @checked_out.decrement
          tokens = explicit_tokens
          tokens.pop
          clear_explicit_tokens if tokens.empty?
          @signal.broadcast
        end
      end

      def explicit_tokens(create: true)
        ownership = Storage.fiber[OWNERSHIP, :strong]
        if create
          ownership ||= Storage.fiber.store_if_absent(OWNERSHIP, mode: :strong) { {}.compare_by_identity }
          ownership[self] ||= []
        else
          ownership&.[](self)
        end
      end

      def clear_explicit_tokens
        Storage.fiber[OWNERSHIP, :strong]&.delete(self)
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        unless timeout.finite? && !timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def next_token = Object.new.freeze

      def validate_resource!(resource)
        return unless nil.equal?(resource) || true.equal?(resource) || false.equal?(resource)

        raise ArgumentError, "lease pool resource cannot be nil or boolean"
      end

      def initialize_storage      = nil
      def finalize_initialization = nil
      def store_resource(*)       = raise(NoMethodError, "abstract lease pool storage")
      def take_resource(*)        = raise(NoMethodError, "abstract lease pool storage")
      def return_resource(*)      = raise(NoMethodError, "abstract lease pool storage")
      def discard_resource(*)     = raise(NoMethodError, "abstract lease pool storage")
    end
  end
end
