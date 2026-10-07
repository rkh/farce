# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A ractor-shareable lazy value that is computed on demand.
  # The factory runs once. Its result is transferred according to {#mode}.
  # With the default `:copy` mode, each Ractor receives its own cached copy.
  # The factory and its bound receiver must remain Ractor-shareable.
  # Use {Strict::Lazy} for direct shareable results or {Unshared::Lazy} for local factories.
  #
  # You can use it to make the following, common Ruby idiom ractor-safe:
  #
  # ```ruby
  # class MyClass
  #   def expensive_attribute = @expensive_attribute ||= compute_expensive_attribute
  #
  #   private
  #
  #   def compute_expensive_attribute
  #     sleep 0.5 # pretend like we're working
  #     42
  #   end
  # end
  #
  # # this will freeze the object without the expensive attribute being computed
  # object = Ractor.make_shareable(MyClass.new)
  #
  # # this will fail
  # Ractor.new(object) { it.expensive_attribute }
  #
  #
  # object = MyClass.new
  #
  # # this will work, but compute the expensive attribute five times, and also deep-copy any other
  # # unshareable data the object might hold
  # 5.times { Ractor.new(object) { it.expensive_attribute } }
  # ```
  #
  # You can use `Farce::Lazy` to make expensive attributes ractor-safe:
  #
  # ```ruby
  # class MyClass
  #   include Farce::Shareable
  #
  #   def initialize
  #     @expensive_attribute = Farce::Lazy.new do
  #       sleep 0.5 # pretend like we're working
  #       42
  #     end
  #     super
  #   end
  #
  #   def expensive_attribute = @expensive_attribute.value
  # end
  #
  # object = MyClass.new
  #
  # # Will only compute the expensive attribute once, and return the same value to all Ractors.
  # 5.times { Ractor.new(object) { it.expensive_attribute } }
  # ```
  class Lazy < Farce::Abstract::Lazy
    include Shareable::Tracked

    # @!macro modes
    # @overload initialize(factory, mode: :copy)
    #   @param factory [Class, Proc, #call] the shareable factory for the value
    #   @param mode [Symbol] the transfer mode for the computed result
    # @overload initialize(mode: :copy, self: nil)
    #   @param mode [Symbol] the transfer mode for the computed result
    #   @param self [BasicObject] the shareable receiver to bind to the block
    #   @yield computes the value on first access
    #   @yieldreturn [BasicObject] the result to transfer
    def initialize(factory = nil, mode: :copy, **, &)
      @manager = marshal_mode_manager(mode)
      super(factory, **, &)
    end

    # @return [Symbol] the transfer mode for the computed result
    def mode = @manager.mode

    # Compute once and return the result according to the configured transfer mode.
    # Repeated reads return the same value within the current Ractor.
    # @return [BasicObject] the computed result
    def value = @manager.unwrap(super)

    # Resolve the slot before freezing it. This does not freeze the result.
    # @return [self]
    def freeze
      value
      internal_atom.freeze
      super
    end

    private

    def compute_value            = @manager.wrap(super)
    def display_value(inspector) = super(inspector, @manager)
  end
end
