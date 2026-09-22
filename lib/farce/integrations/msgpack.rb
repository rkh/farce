# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ActiveSupport Integration
require "farce"
require "msgpack"

module Farce
  class Abstract::Vector
    # Serialize a snapshot as a MessagePack array.
    # @note This method is only available if MessagePack has been loaded.
    # @overload to_msgpack(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to Array#to_msgpack.
    # @return [String, ::MessagePack::Packer] The encoded bytes or supplied packer.
    def to_msgpack(...) = to_a.to_msgpack(...)
  end

  class Abstract::Map
    # Serialize current entries as a MessagePack map.
    # @note This method is only available if MessagePack has been loaded.
    # @overload to_msgpack(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to Hash#to_msgpack.
    # @return [String, ::MessagePack::Packer] The encoded bytes or supplied packer.
    def to_msgpack(...) = to_h.to_msgpack(...)
  end

  class Abstract::Set
    # Serialize current members as a MessagePack array.
    # @note This method is only available if MessagePack has been loaded.
    # @overload to_msgpack(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to Array#to_msgpack.
    # @return [String, ::MessagePack::Packer] The encoded bytes or supplied packer.
    def to_msgpack(...) = to_a.to_msgpack(...)
  end

  module Abstract::ValueSerialization
    # Serialize the current value as its primitive MessagePack equivalent.
    # @note This method is only available if MessagePack has been loaded.
    # @overload to_msgpack(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to the value's to_msgpack.
    # @return [String, ::MessagePack::Packer] The encoded bytes or supplied packer.
    def to_msgpack(...) = value.to_msgpack(...)
  end

  # @note This module is only available if MessagePack has been loaded.
  module MessagePack
    # Default mapping used by {.factory}.
    DEFAULT_TYPES = { Vector => 0, Map => 1, Counter => 2, Flag => 3, Atom => 4, Set => 5 }.freeze

    extend self

    # Build a factory that restores registered Farce classes.
    # Use the same type IDs when writing and reading data.
    # @note This method is only available if MessagePack has been loaded.
    # @param types [Hash{Class => Integer}] Classes and their application extension IDs.
    # @return [::MessagePack::Factory] An independent factory.
    # @!scope class
    def factory(types: DEFAULT_TYPES)
      result = ::MessagePack::Factory.new
      types.each { |klass, type| register_type(result, type, klass) }
      result
    end

    # Register a Farce class on an application-owned factory.
    # Values use the same factory recursively, including nested custom types.
    # Source configuration is replaced by the supplied constructor options.
    # Counters also retain their initial value for reset.
    # @note This method is only available if MessagePack has been loaded.
    # @param factory [::MessagePack::Factory] The factory to configure.
    # @param type [Integer] An unused application extension ID from 0 through 127.
    # @param klass [Class] A concrete Farce vector, map, set, counter, flag, or atom class.
    # @param options [Hash{Symbol => Object}] Constructor options for restored objects.
    # @return [::MessagePack::Factory] The supplied factory.
    # @raise [ArgumentError] If the class is unsupported or the ID or class is already registered.
    # @!scope class
    def register_type(factory, type, klass, **)
      reader = primitive_reader(klass)
      unless type.is_a?(Integer) && (0..127).cover?(type)
        raise ArgumentError, "MessagePack extension IDs must be integers from 0 through 127"
      end
      if factory.registered_types.any? { it[:type] == type || it[:class] == klass }
        raise ArgumentError, "MessagePack extension ID or class is already registered"
      end

      counter = klass <= Abstract::Counter
      factory.register_type(type, klass,
        packer:    lambda { |object, packer|
          packer.write(object.initial) if counter
          packer.write(object.public_send(reader))
        },
        unpacker:  lambda { |unpacker|
          object = klass.new(unpacker.read, **)
          object.value = unpacker.read if counter
          object
        },
        recursive: true)
      factory
    end

    private

    def primitive_reader(klass)
      raise ArgumentError, "expected a concrete Farce class" unless klass.is_a?(Class)
      return :to_a if klass <= Abstract::Vector || klass <= Abstract::Set
      return :to_h if klass <= Abstract::Map
      return :value if klass <= Abstract::Counter || klass <= Abstract::Flag || klass <= Abstract::Atom

      raise ArgumentError, "unsupported Farce class: #{klass}"
    end
  end
end
