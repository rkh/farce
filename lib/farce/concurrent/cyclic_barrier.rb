# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # A replacement for `concurrent-ruby`'s `CyclicBarrier` implementation.
    # @see https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/CyclicBarrier.html
    class CyclicBarrier
      include Shareable::Delegated
      include Internal::Noncopyable

      # @api private
      class Generation
        include Shareable::Delegated

        attr_reader :waiting

        def initialize
          @waiting = Counter.new
          @state   = Strict::Atom.new(:waiting)
          super
        end

        def wait(timeout)  = @state.wait_until_changed(:waiting, timeout:)
        def state          = @state.value
        def number_waiting = state == :waiting ? @waiting.value : 0

        def state=(value)
          @state.value = value
        end

        private def freeze_backend = @waiting
      end
      private_constant :Generation

      # @return [Integer] the number of parties required to trip the barrier.
      attr_reader :parties

      # @param parties [Integer] the number of parties required to trip the barrier.
      # @raise [ArgumentError] if parties is not a positive integer.
      # @yield
      #   Optional block to trigger after the last waiter has arrived at the barrier but before they are released.
      #   Will be made Ractor-shareable. If it raises, the barrier breaks and the exception propagates to its caller.
      def initialize(parties, &)
        raise ArgumentError, "parties must be a positive integer" unless parties.is_a?(Integer) && parties.positive?
        @parties    = parties
        @action     = block_given? ? Ractor.shareable_proc(&) : nil
        @generation = Strict::Atom.new(Generation.new)
        super()
      end

      # @return [Boolean] whether the barrier is in a broken state.
      def broken? = generation.state == :broken

      # @return [Integer] the number of parties currently waiting at the barrier.
      def number_waiting = generation.number_waiting

      # Waits for all parties to reach the barrier. Successful generations can be reused immediately.
      # A timeout breaks the barrier for all waiters until {#reset} is called.
      # @param timeout [Numeric, nil] the maximum time to wait for the barrier.
      # @return [Boolean] true if the barrier was successfully reached, false if it was broken by a timeout or reset.
      def wait(timeout = nil) # rubocop:disable Naming/PredicateMethod
        deadline = Internal.timeout_deadline(timeout)
        waiting  = nil
        update do |current|
          waiting = current
          next current unless current.state == :waiting
          current.waiting.increment
          next current if current.waiting.value < @parties

          completed = false
          begin
            @action&.call
            completed = true
          ensure
            current.state = completed ? :fulfilled : :broken
          end
          Generation.new
        end

        unless waiting.wait(Internal.remaining_timeout(deadline))
          update do |current|
            # A trip or reset may have won the race with this waiter's timeout.
            waiting.state = :broken if waiting.state == :waiting
            current
          end
        end
        waiting.state == :fulfilled
      end

      # Breaks the current generation and starts a new one. Existing waiters return false.
      # @return [nil]
      def reset
        update do |current|
          current.state = :broken
          Generation.new
        end
        nil
      end

      private

      def freeze_backend = @generation
      def generation     = @generation.value
      def update(&)      = @generation.update(&)
    end
  end
end
