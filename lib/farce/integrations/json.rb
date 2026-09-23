# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group JSON Integration
require "farce"
require "json" unless defined?(JSON::State)

module Farce
  class Abstract::Vector
    # Serialize a logical snapshot as a JSON Array.
    # @note This method is only available if JSON has been loaded.
    # @overload to_json(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to Array#to_json.
    #   @return [String] The generated JSON.
    def to_json(...) = to_a.to_json(...)
  end

  class Abstract::Map
    # Serialize current entries as a JSON object.
    # @note This method is only available if JSON has been loaded.
    # @overload to_json(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to Hash#to_json.
    #   @return [String] The generated JSON.
    def to_json(...) = to_h.to_json(...)
  end

  class Abstract::Set
    # Serialize current members as a JSON Array.
    # @note This method is only available if JSON has been loaded.
    # @overload to_json(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to Array#to_json.
    #   @return [String] The generated JSON.
    def to_json(...) = to_a.to_json(...)
  end

  module Abstract::ValueSerialization
    # Serialize the current value as its primitive JSON equivalent.
    # @note This method is only available if JSON has been loaded.
    # @overload to_json(*arguments)
    #   @param arguments [Array<Object>] Arguments forwarded to the current value's to_json.
    #   @return [String] The generated JSON.
    def to_json(...) = value.to_json(...)
  end
end
