# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Mixin that makes sure instances are shareable between Ractors.
  #
  # @example
  #   class MyClass
  #     include Farce::Shareable
  #   end
  #
  #   object = MyClass.new
  #   Ractor.shareable?(object) # => true
  # Shareability and frozen state are independent. Mutable Farce containers begin
  # unfrozen. Their freeze prevents explicit changes to their own contents without
  # freezing stored values. Weak contents can still disappear during garbage collection.
  # Live services, such as queues and locks, reject freeze with TypeError.
  # Coordinate with writers before freezing. Freeze does not wait for operations
  # already in progress and is not a snapshot operation.
  module Shareable
    # A structurally frozen wrapper whose logical frozen state is owned by its backend.
    # The including class must implement a private `freeze_backend` method.
    #
    # @example Delegate freezing to a counter
    #   class Tally
    #     include Farce::Shareable::Delegated
    #
    #     def initialize
    #       @counter = Farce::Counter.new
    #       super
    #     end
    #
    #     def increment = @counter.increment
    #     private def freeze_backend = @counter
    #   end
    #
    #   tally = Tally.new
    #   tally.frozen?  # => false
    #   tally.freeze
    #   tally.increment # raises FrozenError in the counter
    module Delegated
      include Shareable
      include Internal::Freeze::Delegated
    end

    # A structurally frozen wrapper with one shared logical freeze-state flag.
    # Mutating methods must call `check_frozen!` before changing state.
    #
    # @example Track freezing separately from storage
    #   class Tally
    #     include Farce::Shareable::Tracked
    #
    #     def initialize
    #       @counter = Farce::Counter.new
    #       super
    #     end
    #
    #     def increment
    #       check_frozen!
    #       @counter.increment
    #     end
    #   end
    #
    #   tally = Tally.new
    #   tally.frozen? # => false
    #   tally.freeze
    #   tally.increment # raises FrozenError for the tally
    module Tracked
      include Shareable
      include Internal::Freeze::Tracked
    end

    # A structurally frozen service object that does not support logical freezing.
    #
    # @example Publish a service that must remain mutable
    #   class Inbox
    #     include Farce::Shareable::Unfreezable
    #
    #     def initialize
    #       @queue = Farce::Queue.new
    #       super
    #     end
    #
    #     def push(value) = @queue.push(value)
    #   end
    #
    #   inbox = Inbox.new
    #   inbox.frozen? # => false
    #   inbox.freeze  # raises TypeError
    module Unfreezable
      include Shareable
      include Internal::Freeze::Unfreezable
    end

    # A native object that publishes its initialized payload without structural freezing.
    # Requires a backend that already implements safe publication and frozen checks.
    # Including this module alone cannot make an ordinary Ruby object shareable.
    # Native subclasses must not add Ruby instance variables on CRuby.
    #
    # @example Extend a counter while preserving native publication
    #   class Tally < Farce::Counter
    #     include Farce::Shareable::Native
    #
    #     def increment_twice = increment(2)
    #   end
    #
    #   tally = Tally.new
    #   tally.frozen? # => false
    #   Ractor.shareable?(tally) # => true
    #   tally.freeze
    #   tally.increment_twice # raises FrozenError
    module Native
      include Shareable
      include Internal::Freeze::Native
    end

    # An immutable object whose structural and logical frozen states are the same.
    # Set instance variables before calling `super` from `initialize`.
    #
    # @example Publish an immutable value
    #   class Point
    #     include Farce::Shareable::Immutable
    #     attr_reader :x, :y
    #
    #     def initialize(x, y)
    #       @x, @y = x, y
    #       super()
    #     end
    #   end
    #
    #   point = Point.new(1, 2)
    #   point.frozen? # => true
    #   Ractor.shareable?(point) # => true
    module Immutable
      include Shareable
      include Internal::Freeze::Immutable
    end

    # Make sure to call `super` if you include this module.
    # Accepts any arguments and passes them on to the superclass initializer.
    def initialize(...)
      super
      publish_shareable
    end

    # @return [Boolean] true
    # @see Unshareable#ractor_shareable?
    def ractor_shareable? = true

    private

    # Publish a Ruby facade without dispatching its logical `freeze` method.
    def publish_shareable = Internal::Freeze.publish(self)
  end
end
