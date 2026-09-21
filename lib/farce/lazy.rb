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
  class Lazy < Farce::Abstract::Lazy
    include Shareable::Tracked

    # Resolve the slot before freezing it. The resolved value remains mutable.
    # @return [self]
    def freeze
      value
      internal_atom.freeze
      super
    end
  end
end
