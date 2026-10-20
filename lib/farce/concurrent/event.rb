# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Concurrent
    # A replacement for `concurrent-ruby`'s `Event` implementation.
    # @see https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/Event.html
    class Event
      include Shareable::Delegated
      include Internal::Noncopyable

      def initialize
        # Odd generations are set. Even generations are reset without forgetting earlier signals.
        @state = Strict::Atom.new(0)
        super
      end

      # @return [Boolean] whether the event is currently set.
      def set? = @state.value.odd?

      # Sets the event.
      # @return [true] always returns `true`.
      def set # rubocop:disable Naming/PredicateMethod
        try?
        true
      end

      # @return [Boolean] `true` if the event was successfully set, `false` otherwise.
      def try?
        changed = false
        @state.update do |current|
          next current if current.odd?
          changed = true
          current + 1
        end
        changed
      end

      # @return [true] always returns `true`.
      def reset # rubocop:disable Naming/PredicateMethod
        @state.update { |current| current.odd? ? current + 1 : current }
        true
      end

      # Waits for the event to be set or for the specified timeout to elapse.
      # Resetting the event does not retract a signal already sent to current waiters.
      # @param timeout [Numeric, nil] the maximum number of seconds to wait, or `nil` to wait indefinitely.
      # @return [Boolean] `true` if the event was set, `false` if the timeout elapsed.
      def wait(timeout = nil) # rubocop:disable Naming/PredicateMethod
        deadline = Internal.timeout_deadline(timeout)
        observed = @state.value
        return true if observed.odd?
        !!@state.wait_until_changed(observed, timeout: Clock.remaining(deadline))
      end

      private def freeze_backend = @state
    end
  end
end
