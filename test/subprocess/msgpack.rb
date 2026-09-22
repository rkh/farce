# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/msgpack"
require "stringio"

module Farce
  class MessagePackTests < Test
    def test_primitive_encoding_and_packer_arguments
      objects = [Vector.new([1, false, nil]), Map.new({ "a" => 1 }), Set.new([1]),
                 Counter.new(2).increment(3), Flag.new, Flag.new(true), Atom.new, Atom.new(false)]
      primitives = [[1, false, nil], { "a" => 1 }, [1], 5, false, true, nil, false]
      objects.zip(primitives).each do |object, primitive|
        assert_equal primitive.to_msgpack, object.to_msgpack
        assert_equal primitive.to_msgpack, ::MessagePack.pack(object)
        packer = ::MessagePack::Packer.new

        assert_same packer, object.to_msgpack(packer)
        assert_equal primitive.to_msgpack, packer.to_s
        output = StringIO.new.binmode
        object.to_msgpack(output)

        assert_equal primitive.to_msgpack, output.string
      end
    end

    def test_nested_primitive_values
      source = Vector.new([Map.new({ "count" => Counter.new(7) }), Atom.new(Flag.new(true))])

      assert_equal [{ "count" => 7 }, true], ::MessagePack.unpack(::MessagePack.pack(source))
    end

    def test_factory_restores_nested_types_and_independent_containers
      factory = MessagePack.factory
      counter = Counter.new(2).increment(3)
      source = Vector.new([Map.new({ "count" => counter }), Atom.new(Flag.new(true)), Set.new([1, 2])])
      copy = factory.load(factory.dump(source))

      assert_instance_of Vector, copy
      assert_instance_of Map, copy[0]
      assert_instance_of Counter, copy[0]["count"]
      assert_equal 5, copy[0]["count"].value
      assert_equal 2, copy[0]["count"].reset.value
      assert_equal 5, counter.value
      assert_instance_of Atom, copy[1]
      assert_instance_of Flag, copy[1].value
      assert copy[1].value.value
      assert_instance_of Set, copy[2]
      assert_equal [1, 2], copy[2].to_a.sort
      copy << 42

      assert_equal 3, source.size
      assert_equal([nil, false], [nil, false].map { factory.load(factory.dump(Atom.new(it))).value })
    end

    def test_custom_factory_and_nested_application_extension
      point = Struct.new(:x)
      factory = ::MessagePack::Factory.new
      factory.register_type(50, point, packer: ->(value) { value.x.to_s }, unpacker: ->(data) { point.new(data.to_i) })
      MessagePack.register_type(factory, 51, Unshared::Vector)
      copy = factory.load(factory.dump(Unshared::Vector.new([point.new(12)])))

      assert_instance_of Unshared::Vector, copy
      assert_instance_of point, copy[0]
      assert_equal 12, copy[0].x
      assert_equal([50, 51], factory.registered_types.map { it[:type] })
    end

    def test_custom_ids_and_local_constructor_options
      factory = MessagePack.factory(types: { Flag => 42 })

      assert_instance_of Flag, factory.load(factory.dump(Flag.new))
      MessagePack.register_type(factory, 43, Local::Counter, scope: :fiber)
      source = Local::Counter.new(4, scope: :fiber).increment(2)
      copy = factory.load(factory.dump(source))

      assert_equal :fiber, copy.scope
      assert_equal 6, copy.value
      assert_equal 4, Fiber.new { copy.value }.resume
      assert_equal 4, copy.reset.value
    end

    def test_variants_use_primitive_encoding
      [Strict::Vector, Unshared::Vector, Local::Vector].each do |type|
        assert_equal [1, 2].to_msgpack, type.new([1, 2]).to_msgpack
      end
      [Strict::Map, Unshared::Map, Local::Map].each do |type|
        assert_equal({ "x" => 1 }.to_msgpack, type.new({ "x" => 1 }).to_msgpack)
      end
      [Strict::Atom, Local::Atom, Local::Counter, Local::Flag].each do |type|
        object = type.new

        assert_equal object.value.to_msgpack, object.to_msgpack
      end
    end

    def test_factory_does_not_change_global_packing
      factory = MessagePack.factory
      source = Vector.new([1])

      assert_equal [1].to_msgpack, source.to_msgpack
      assert_equal [1].to_msgpack, ::MessagePack.pack(source)
      assert_raises(::MessagePack::UnknownExtTypeError) { ::MessagePack.unpack(factory.dump(source)) }
      refute_predicate Farce.config, :frozen?
    end

    def test_registration_rejects_collisions_and_unsupported_types
      factory = MessagePack.factory
      before = factory.registered_types

      assert_raises(ArgumentError) { MessagePack.register_type(factory, 0, Local::Vector) }
      assert_raises(ArgumentError) { MessagePack.register_type(factory, 40, Vector) }
      assert_raises(ArgumentError) { MessagePack.register_type(factory, 40, String) }
      assert_raises(ArgumentError) { MessagePack.register_type(factory, 128, Local::Vector) }
      assert_equal before, factory.registered_types
    end
  end
end
