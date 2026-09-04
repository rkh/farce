# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # Mixin to indicate {#value} can safely be called on an object.
    #
    # @!method value
    #   @abstract
    #   Can be called multiple times without argument.
    #   Some subclasses may allow optional arguments, especially a `timeout` keyword argument.
    #   This method may block.
    #   @return [BasicObject] The underlying value of the object.
    #
    # @abstract
    module Value
      Internal::Atom.include(self)

      # Unwraps nested {Value} objects to get the underlying value.
      #
      # @example Nested unwrapping
      #   MyValue = Data.define(:value) { include Farce::Abstract::Value }
      #   inner   = MyValue.new(42)
      #   outer   = MyValue.new(inner)
      #   outer.unwrap # => 42
      #
      # @example Cycle detection
      #   MyValue = Struct.new(:name, :value) { include Farce::Abstract::Value }
      #
      #   a = MyValue.new("A")
      #   b = MyValue.new("B", a)
      #   c = MyValue.new("C", a)
      #   a.value = b
      #
      #   c.unwrap # => nil
      #   c.unwrap("default") # => "default"
      #
      #   # RuntimeError: cycle detected starting at A
      #   c.unwrap { raise "cycle detected starting at #{value.name}" }
      #
      # @overload unwrap(default = nil)
      #   @param [BasicObject] default The value to return if a cycle is detected.
      #
      # @overload unwrap
      #   @yield [value] Block to call if a cycle is detected.
      #   @yieldparam [Value] value The value that has been determined to be the start of the cycle.
      #   @yieldreturn [BasicObject] The value to return if a cycle is detected
      #
      # @return [BasicObject] The underlying value of the object, or a default value based on the argument or block.
      def unwrap(default = nil)
        value = value()
        return value unless value.is_a?(Value)

        seen = Set.new.compare_by_identity
        seen << self

        while value.is_a?(Value)
          return block_given? ? yield(value) : default if seen.include?(value)
          seen << value
          value = value.value
        end

        value
      end
    end
  end
end
