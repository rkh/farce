# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/cbor"
require "stringio"

module Farce
  class CBORTests < Test
    def test_primitive_encoding_and_packer_arguments
      objects = [Vector.new([1, false, nil]), Map.new({ "a" => 1 }), Set.new([1]),
                 Counter.new(2).increment(3), Flag.new, Flag.new(true), Atom.new, Atom.new(false)]
      primitives = [[1, false, nil], { "a" => 1 }, [1], 5, false, true, nil, false]
      objects.zip(primitives).each do |object, primitive|
        assert_equal primitive.to_cbor, object.to_cbor
        assert_equal primitive.to_cbor, ::CBOR.encode(object)
        packer = ::CBOR::Packer.new

        assert_same packer, object.to_cbor(packer)
        assert_equal primitive.to_cbor, packer.to_s
        output = StringIO.new.binmode

        assert_nil object.to_cbor(output)
        assert_equal primitive.to_cbor, output.string
      end
    end

    def test_nested_values_in_farce_and_ruby_containers
      source = Vector.new([Map.new({ "count" => Counter.new(7) }), Atom.new(Flag.new(true)), Set.new([2, 1])])
      decoded = ::CBOR.decode(::CBOR.encode(source))

      assert_equal [{ "count" => 7 }, true], decoded.first(2)
      assert_equal [1, 2], decoded.last.sort
      assert_equal({ "values" => decoded }, ::CBOR.decode(::CBOR.encode({ "values" => source })))
      assert_equal({ 3 => [false, nil] },
        ::CBOR.decode(::CBOR.encode({ Counter.new(3) => [Flag.new, Atom.new] })))
    end

    def test_cbor_tagged_values_and_binary_strings
      tagged = ::CBOR::Tagged.new(42, Vector.new([Atom.new("hello"), "\x00\xff".b]))
      decoded = ::CBOR.decode(Atom.new(tagged).to_cbor)

      assert_instance_of ::CBOR::Tagged, decoded
      assert_equal 42, decoded.tag
      assert_equal ["hello", "\x00\xff".b], decoded.value
      assert_equal Encoding::ASCII_8BIT, decoded.value.last.encoding
    end

    def test_variants_use_primitive_encoding
      [Farce, Strict, Unshared, Local].each do |namespace|
        vector = namespace::Vector.new([1, 2])
        map = namespace::Map.new({ "x" => 1 })
        set = namespace::Set.new([2, 1])

        assert_equal [1, 2], ::CBOR.decode(vector.to_cbor)
        assert_equal({ "x" => 1 }, ::CBOR.decode(map.to_cbor))
        assert_equal [1, 2], ::CBOR.decode(set.to_cbor).sort
        [namespace::Atom, namespace::Counter, namespace::Flag].each do |type|
          object = type.new

          assert_equal object.value.to_cbor, object.to_cbor
        end
      end
    end

    def test_streaming_multiple_values
      packer = ::CBOR::Packer.new
      source = Vector.new([Counter.new(3)])
      source.to_cbor(packer)
      Flag.new(true).to_cbor(packer)
      unpacker = ::CBOR::Unpacker.new
      unpacker.feed(packer.to_s)

      assert_equal [3], unpacker.read
      assert unpacker.read
    end
  end
end
