# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/bson"

module Farce
  class BSONTests < Test
    class ChangingAtom < Atom
      def value
        current = super
        self.value = "changed"
        current
      end
    end

    class ChangingCounter < Counter
      def value
        current = super
        self.value = 1 << 40
        current
      end
    end

    def test_standard_encoding_and_buffer_arguments
      objects = [Vector.new([1, false, nil]), Map.new({ "a" => 1 }), Set.new([1]),
                 Counter.new(2).increment(3), Flag.new, Flag.new(true), Atom.new, Atom.new(false)]
      ordinary = [[1, false, nil], { "a" => 1 }, [1], 5, false, true, nil, false]
      objects.zip(ordinary).each do |object, value|
        assert_equal value.to_bson.to_s, object.to_bson.to_s
        buffer = ::BSON::ByteBuffer.new
        buffer.put_bytes("prefix")

        assert_same buffer, object.to_bson(buffer)
        assert_equal "prefix#{value.to_bson}", buffer.to_s
      end
    end

    def test_nested_mixed_containers_and_value_wrappers
      source = Map.new({ "items" => [Vector.new([Map.new({ "count" => Counter.new(7) })]),
                                     { "enabled" => Atom.new(Flag.new(true)) }, Set.new([2])] })
      expected = { "items" => [[{ "count" => 7 }], { "enabled" => true }, [2]] }

      assert_equal expected.to_bson.to_s, source.to_bson.to_s
      assert_equal expected, decode_document(source.to_bson.to_s)
    end

    def test_collections_embed_in_ordinary_ruby_hashes_and_arrays
      source = [Vector.new([1]), Map.new({ "x" => 2 }), Set.new([3])]
      expected = [[1], { "x" => 2 }, [3]]

      assert_equal expected.to_bson.to_s, source.to_bson.to_s
      assert_equal({ "values" => expected }, decode_document({ "values" => source }.to_bson.to_s))
    end

    def test_document_normalization_captures_value_wrappers
      source = { "count" => Counter.new(5), "enabled" => Flag.new(true),
                 "items" => Atom.new(Vector.new([1, Map.new({ "x" => 2 })])) }
      normalized = ::BSON::Document.new(source)
      expected = { "count" => 5, "enabled" => true, "items" => [1, { "x" => 2 }] }

      assert_equal expected, normalized
      assert_equal expected.to_bson.to_s, normalized.to_bson.to_s
      source["count"].increment
      source["enabled"].unset
      source["items"].value << 3

      assert_equal expected, normalized
    end

    def test_wrapper_values_are_captured_before_encoding_the_type
      source = Map.new({ "atom" => ChangingAtom.new(7), "counter" => ChangingCounter.new(8) })

      assert_equal({ "atom" => 7, "counter" => 8 }, decode_document(source.to_bson.to_s))
      assert_equal "changed", source["atom"].value
      assert_equal 1 << 40, source["counter"].value
    end

    def test_stored_values_are_captured_once_for_direct_encoding
      assert_equal 7.to_bson.to_s, ChangingAtom.new(7).to_bson.to_s
      assert_equal 8.to_bson.to_s, ChangingCounter.new(8).to_bson.to_s
    end

    def test_bson_values_survive_collection_encoding
      id = ::BSON::ObjectId.from_string("573a1391f29313caabcd9637")
      binary = ::BSON::Binary.new("bytes")
      time = Time.utc(2026, 10, 7, 12, 0, 0)
      source = Map.new({ "id" => id, "binary" => binary, "time" => time, "long" => 1 << 40 })
      expected = { "id" => id, "binary" => binary, "time" => time, "long" => 1 << 40 }

      assert_equal source.to_h.to_bson.to_s, source.to_bson.to_s
      assert_equal expected, decode_document(source.to_bson.to_s)
      normalized = source.to_bson_normalized_value

      assert_instance_of ::BSON::ObjectId, normalized["id"]
      assert_instance_of ::BSON::Binary, normalized["binary"]
    end

    def test_key_normalization_and_errors_follow_bson
      source = Map.new({ name: Vector.new(["Farce"]) })
      key = Object.new.freeze
      invalid = Map.new({ key => 1 })

      assert_equal({ "name" => ["Farce"] }, decode_document(source.to_bson.to_s))
      assert_raises(::BSON::Error::InvalidKey) { invalid.to_bson }
    end

    def test_variants_share_standard_encoding
      [Vector, Strict::Vector, Unshared::Vector, Unsafe::Vector, Local::Vector].each do |type|
        assert_equal [1, 2].to_bson.to_s, type.new([1, 2]).to_bson.to_s
      end
      [Map, Strict::Map, Unshared::Map, Unsafe::Map, Local::Map].each do |type|
        assert_equal({ "x" => 1 }.to_bson.to_s, type.new({ "x" => 1 }).to_bson.to_s)
      end
      [Set, Strict::Set, Unshared::Set, Unsafe::Set, Local::Set].each do |type|
        assert_equal [1].to_bson.to_s, type.new([1]).to_bson.to_s
      end
      [Atom, Strict::Atom, Unshared::Atom, Unsafe::Atom, Local::Atom,
       Counter, Strict::Counter, Unshared::Counter, Unsafe::Counter, Local::Counter,
       Flag, Strict::Flag, Unshared::Flag, Unsafe::Flag, Local::Flag].each do |type|
        object = type.new

        assert_equal object.value.to_bson.to_s, object.to_bson.to_s
      end
    end

    def test_extended_json_for_collections_and_value_wrappers
      id = ::BSON::ObjectId.from_string("573a1391f29313caabcd9637")
      source = Map.new({ "items" => Vector.new([id, Counter.new(1 << 40), Atom.new(Flag.new(true)),
                                                Set.new([2])]) })
      expected = { "items" => [id, 1 << 40, true, [2]] }
      [nil, :relaxed, :legacy].each do |mode|
        assert_equal expected.as_extended_json(mode:), source.as_extended_json(mode:)
        assert_equal expected.to_extended_json(mode:), source.to_extended_json(mode:)
      end
      assert_equal [1].as_extended_json, Vector.new([Counter.new(1)]).as_extended_json
      assert_equal [1].as_extended_json, Set.new([1]).as_extended_json
      assert_equal({ "$numberInt" => "7" }, ChangingAtom.new(7).as_extended_json)
    end

    def test_enfarce_imports_standard_bson_and_extended_json
      id = ::BSON::ObjectId.from_string("573a1391f29313caabcd9637")
      source = { "items" => [{ "id" => id, "count" => 3 }] }
      [decode_document(source.to_bson.to_s), ::BSON::ExtJSON.parse(source.to_extended_json)].each do |document|
        result = Farce.enfarce(document)

        assert_instance_of Map, result
        assert_instance_of Vector, result["items"]
        assert_instance_of Map, result["items"][0]
        assert_equal id, result["items"][0]["id"]
        assert_equal 3, result["items"][0]["count"]
      end
    end

    def test_standard_document_decodes_without_farce
      bytes = Map.new({ "items" => Vector.new([Counter.new(7), Atom.new(Flag.new(true)), Set.new([2])]) }).to_bson.to_s
      env = ENV.keys.grep(/\ABUNDLE/).to_h { [it, nil] }.merge("RUBYOPT" => nil, "RUBYLIB" => nil)
      output, error, status = ruby_subprocess(<<~RUBY, env:, coverage: false)
        require "bson"
        raise "Farce loaded" if defined?(Farce)
        bytes = #{bytes.unpack1("H*").inspect}.then { [it].pack("H*") }
        document = Hash.from_bson(BSON::ByteBuffer.new(bytes))
        raise "wrong document" unless document == { "items" => [7, true, [2]] }
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    private

    def decode_document(bytes) = Hash.from_bson(::BSON::ByteBuffer.new(bytes))
  end
end
