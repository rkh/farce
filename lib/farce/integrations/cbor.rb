# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group CBOR Integration
require "farce"
require "cbor"

module Farce
  class Abstract::Vector
    # @overload to_cbor(*arguments)
    #   @note This method is only available if CBOR has been loaded.
    #   @note On CRuby, CBOR's native encoder must run in the main Ractor.
    #   Serialize a snapshot as a CBOR array.
    #   @example
    #     CBOR.decode(Farce::Vector.new([1, false]).to_cbor) # => [1, false]
    #   @param arguments [Array<Object>] Arguments forwarded to Array#to_cbor.
    #   @return [String, ::CBOR::Packer, nil] Encoded bytes, the supplied packer, or nil when writing to IO.
    def to_cbor(...) = to_a.to_cbor(...)
  end

  class Abstract::Map
    # @overload to_cbor(*arguments)
    #   @note This method is only available if CBOR has been loaded.
    #   @note On CRuby, CBOR's native encoder must run in the main Ractor.
    #   Serialize current entries as a CBOR map.
    #   @param arguments [Array<Object>] Arguments forwarded to Hash#to_cbor.
    #   @return [String, ::CBOR::Packer, nil] Encoded bytes, the supplied packer, or nil when writing to IO.
    def to_cbor(...) = to_h.to_cbor(...)
  end

  class Abstract::Set
    # @overload to_cbor(*arguments)
    #   @note This method is only available if CBOR has been loaded.
    #   @note On CRuby, CBOR's native encoder must run in the main Ractor.
    #   Serialize current members as a CBOR array.
    #   @param arguments [Array<Object>] Arguments forwarded to Array#to_cbor.
    #   @return [String, ::CBOR::Packer, nil] Encoded bytes, the supplied packer, or nil when writing to IO.
    def to_cbor(...) = to_a.to_cbor(...)
  end

  module Internal::ValueSerialization
    # @overload to_cbor(*arguments)
    #   @note This method is only available if CBOR has been loaded.
    #   @note On CRuby, CBOR's native encoder must run in the main Ractor.
    #   Serialize the current value using its CBOR representation.
    #   @param arguments [Array<Object>] Arguments forwarded to the value's to_cbor.
    #   @return [String, ::CBOR::Packer, nil] Encoded bytes, the supplied packer, or nil when writing to IO.
    def to_cbor(...) = value.to_cbor(...)
  end
end
