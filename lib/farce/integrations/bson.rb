# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group BSON Integration
require "farce"
require "bson"

module Farce
  class Abstract::Vector
    # @note This method is only available if BSON has been loaded.
    # Serialize a snapshot using BSON's array representation.
    # Nested value wrappers are read before encoding their BSON types and payloads.
    # @param buffer [BSON::ByteBuffer] An optional buffer to append to.
    # @return [BSON::ByteBuffer] The buffer containing the encoded array.
    def to_bson(buffer = ::BSON::ByteBuffer.new) = to_bson_normalized_value.to_bson(buffer)

    # @note This method is only available if BSON has been loaded.
    # Identify this value as a BSON array when embedded in a document or array.
    # @return [String] The BSON array type byte.
    def bson_type = ::BSON::Array::BSON_TYPE

    # @note This method is only available if BSON has been loaded.
    # Return a snapshot with nested values normalized by BSON.
    # @return [Array] The normalized array.
    def to_bson_normalized_value = to_a.to_bson_normalized_value

    # @overload as_extended_json(**options)
    #   @note This method is only available if BSON has been loaded.
    #   Represent a snapshot as Extended JSON, forwarding BSON's format options.
    #   @param options [Hash] Options forwarded to Array#as_extended_json.
    #   @return [Array] The Extended JSON representation.
    def as_extended_json(**) = to_a.as_extended_json(**)
  end

  class Abstract::Map
    # @note This method is only available if BSON has been loaded.
    # Serialize current entries as a BSON document.
    # Nested value wrappers are read before encoding their BSON types and payloads.
    # @param buffer [BSON::ByteBuffer] An optional buffer to append to.
    # @return [BSON::ByteBuffer] The buffer containing the encoded document.
    def to_bson(buffer = ::BSON::ByteBuffer.new) = to_bson_normalized_value.to_bson(buffer)

    # @note This method is only available if BSON has been loaded.
    # Identify this value as a BSON document when embedded in a document or array.
    # @return [String] The BSON document type byte.
    def bson_type = ::BSON::Hash::BSON_TYPE

    # @note This method is only available if BSON has been loaded.
    # Return current entries with keys and nested values normalized by BSON.
    # @return [BSON::Document] The normalized document.
    def to_bson_normalized_value = to_h.to_bson_normalized_value

    # @overload as_extended_json(**options)
    #   @note This method is only available if BSON has been loaded.
    #   Represent current entries as Extended JSON, forwarding BSON's format options.
    #   @param options [Hash] Options forwarded to Hash#as_extended_json.
    #   @return [Hash] The Extended JSON representation.
    def as_extended_json(**) = to_h.as_extended_json(**)
  end

  class Abstract::Set
    # @note This method is only available if BSON has been loaded.
    # Serialize current members using BSON's array representation.
    # Nested value wrappers are read before encoding their BSON types and payloads.
    # @param buffer [BSON::ByteBuffer] An optional buffer to append to.
    # @return [BSON::ByteBuffer] The buffer containing the encoded array.
    def to_bson(buffer = ::BSON::ByteBuffer.new) = to_bson_normalized_value.to_bson(buffer)

    # @note This method is only available if BSON has been loaded.
    # Identify this value as a BSON array when embedded in a document or array.
    # @return [String] The BSON array type byte.
    def bson_type = ::BSON::Array::BSON_TYPE

    # @note This method is only available if BSON has been loaded.
    # Return current members with nested values normalized by BSON.
    # @return [Array] The normalized array.
    def to_bson_normalized_value = to_a.to_bson_normalized_value

    # @overload as_extended_json(**options)
    #   @note This method is only available if BSON has been loaded.
    #   Represent current members as Extended JSON, forwarding BSON's format options.
    #   @param options [Hash] Options forwarded to Array#as_extended_json.
    #   @return [Array] The Extended JSON representation.
    def as_extended_json(**) = to_a.as_extended_json(**)
  end

  module Internal::ValueSerialization
    # @note This method is only available if BSON has been loaded.
    # Serialize the current stored value using its BSON representation.
    # Use BSON::Document.new when embedding value wrappers in ordinary Ruby hashes.
    # @param buffer [BSON::ByteBuffer] An optional buffer to append to.
    # @return [BSON::ByteBuffer] The buffer containing the encoded value.
    def to_bson(buffer = ::BSON::ByteBuffer.new) = to_bson_normalized_value.to_bson(buffer)

    # @note This method is only available if BSON has been loaded.
    # Read the stored value once and normalize it for BSON encoding.
    # @return [Object] The normalized current value.
    def to_bson_normalized_value = value.to_bson_normalized_value

    # @overload as_extended_json(**options)
    #   @note This method is only available if BSON has been loaded.
    #   Represent the current value as Extended JSON, forwarding BSON's format options.
    #   @param options [Hash] Options forwarded to the value's as_extended_json.
    #   @return [Object] The Extended JSON representation.
    def as_extended_json(**) = value.as_extended_json(**)
  end
end
