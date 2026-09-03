# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A ractor-shareable lazy value that is computed on demand.
  # The value is computed only once, and subsequent calls to `value` will return the same value.
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
  class Lazy
    include Shareable
    include Abstract::Value

    # @overload initialize(factory)
    #   @param [Class, Proc, #call] factory The factory to use for creating the value. Must be ractor-shareable.
    #
    # @overload initialize(self: nil)
    #   @yield The block to use for creating the value. Must be ractor-shareable.
    #   @yieldreceiver [BasicObject] The `self` parameter provided, or `nil` if not provided.
    #   @yieldreturn [BasicObject] The value to be returned by the lazy instance.
    #   @param [BasicObject] self The `self` parameter to be provided to the block. Must be ractor-shareable.
    def initialize(factory = nil, **, &block)
      if block_given?
        raise ArgumentError, "factory and block cannot be both given" unless factory.nil?
        factory = block
      end

      factory  = Ractor.shareable_proc(**, &factory) if factory.is_a?(Proc)
      @factory = factory
      @atom    = Internal::Atom.new
      super()
    end

    # The first time this method is called, the value will be computed based on the factory provided.
    # Subsequent calls will return the same value.
    #
    # This is thread-safe and may be called from any Ractor, even concurrently.
    # @return [BasicObject] The value computed by the factory.
    def value
      value = @atom.store_if_absent do
        value = @factory.is_a?(Class) ? @factory.new : @factory.call
        value.nil? ? UNDEFINED : value
      end
      value unless UNDEFINED.equal?(value)
    end

    # @return [String] Returns a string representation of the lazy instance.
    def inspect = "#<#{self.class.name} #{display_value.inspect}>"

    # @api private
    # @return [void]
    def pretty_print(pp) = pp.group(1, "#<#{self.class.name} ", ">") { pp.pp(display_value) }

    private

    def display_value
      value = @atom.value
      return @factory if value.nil?

      value unless UNDEFINED.equal?(value)
    end

    # Delegates all method calls to {#value}.
    def method_missing(...) = value.public_send(...)
    def respond_to_missing?(...) = value.respond_to?(...)
  end
end
