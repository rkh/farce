# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Low-level operations shared by native TruffleRuby's ordered arrays.
    # Bound primitive methods protect stored String snapshots and identity
    # checks from user overrides.
    module TruffleOrderedArraySupport
      INTERRUPT_IMMEDIATE          = { Exception => :immediate }.freeze
      BASIC_OBJECT_EQUAL           = BasicObject.instance_method(:equal?)
      CLASS_ALLOCATE               = Class.instance_method(:allocate)
      OBJECT_CLASS                 = Object.instance_method(:class)
      OBJECT_FREEZE                = Object.instance_method(:freeze)
      OBJECT_FROZEN                = Object.instance_method(:frozen?)
      OBJECT_INSTANCE_VARIABLES    = Object.instance_method(:instance_variables)
      OBJECT_INSTANCE_VARIABLE_GET = Object.instance_method(:instance_variable_get)
      OBJECT_INSTANCE_VARIABLE_SET = Object.instance_method(:instance_variable_set)
      OBJECT_IS_A                  = Object.instance_method(:is_a?)
      STRING_INITIALIZE_COPY       = String.instance_method(:initialize_copy)
      STRING_UMINUS                = String.instance_method(:-@)

      private_constant :BASIC_OBJECT_EQUAL, :CLASS_ALLOCATE, :OBJECT_CLASS, :OBJECT_FREEZE,
        :OBJECT_FROZEN, :OBJECT_INSTANCE_VARIABLES,
        :OBJECT_INSTANCE_VARIABLE_GET, :OBJECT_INSTANCE_VARIABLE_SET,
        :OBJECT_IS_A, :STRING_INITIALIZE_COPY, :STRING_UMINUS

      private

      def primitive_freeze(object)          = OBJECT_FREEZE.bind_call(object)
      def primitive_frozen?(object)         = OBJECT_FROZEN.bind_call(object)
      def primitive_is_a?(object, klass)    = OBJECT_IS_A.bind_call(object, klass)
      def primitive_identical?(left, right) = BASIC_OBJECT_EQUAL.bind_call(left, right)

      def canonical_ordered_key(key)
        return key unless primitive_is_a?(key, String)
        return STRING_UMINUS.bind_call(key) if
          primitive_identical?(OBJECT_CLASS.bind_call(key), String)

        snapshot_ordered_key(key)
      end

      def snapshot_ordered_key(key)
        return key unless primitive_is_a?(key, String)

        copy = CLASS_ALLOCATE.bind_call(OBJECT_CLASS.bind_call(key))
        STRING_INITIALIZE_COPY.bind_call(copy, key)
        OBJECT_INSTANCE_VARIABLES.bind_call(key).each do |name|
          value = OBJECT_INSTANCE_VARIABLE_GET.bind_call(key, name)
          OBJECT_INSTANCE_VARIABLE_SET.bind_call(copy, name, value)
        end
        primitive_freeze(copy)
      end

      def without_async_interrupts(&)
        Thread.handle_interrupt(INTERRUPT_MASK, &)
      end

      def with_interruptible_callbacks(&)
        Thread.handle_interrupt(INTERRUPT_IMMEDIATE, &)
      end
    end
    private_constant :TruffleOrderedArraySupport
  end
end
