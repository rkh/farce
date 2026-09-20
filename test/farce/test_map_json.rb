# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "json"

module Farce
  class TestMapJson < Test
    def test_as_json_without_active_support_returns_an_independent_hash
      refute_respond_to({}, :as_json)
      [Map, Strict::Map, Unshared::Map, Local::Map, WeakKeyMap, Strict::WeakValueMap,
       Strict::WeakMap, TreeMap, LRUMap, LFUMap].each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 3 } : {}
        map = type.new({ a: 1, b: nil, c: false }, **options)
        result = map.as_json(only: :a)

        assert_instance_of Hash, result
        assert_equal({ a: 1, b: nil, c: false }, result)
        result.clear

        assert_equal({ a: 1, b: nil, c: false }, map.to_h)
      end
    end

    def test_as_json_preserves_identity_keys_without_active_support
      first = String.new("key").freeze
      second = String.new("key").freeze
      map = Map.new(compare_keys_by_identity: true)
      map[first] = 1
      map[second] = 2
      result = map.as_json

      assert_predicate result, :compare_by_identity?
      assert_equal 2, result.size
      assert_equal 1, result[first]
      assert_equal 2, result[second]
    end

    def test_json_serializes_unwrapped_values_and_nested_maps
      nested = Map.new({ enabled: false })
      map = Map.new({ items: [1, nil], nested: }, mode: :copy)
      expected = { "items" => [1, nil], "nested" => { "enabled" => false } }

      assert_equal [1, nil], map.as_json[:items]
      assert_equal expected, JSON.parse(map.to_json)
      assert_equal [expected], JSON.parse(JSON.generate([map]))
      assert_equal JSON.pretty_generate(map.to_h), JSON.pretty_generate(map)
      assert_equal({}, Map.new.as_json)
    end

    def test_active_support_conversion_and_json_options
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        require "active_support/json"

        nested = Farce::Map.new({ visible: 2, hidden: 3 })
        map = Farce::Map.new({ visible: 1, hidden: nil, nested: })
        options = { only: [:visible, :nested] }
        puts JSON.generate([
          map.as_json,
          map.as_json(options),
          map.as_json(except: :hidden),
          JSON.parse(map.to_json(only: :visible)),
          JSON.parse(map.to_json(except: :hidden)),
          JSON.parse(ActiveSupport::JSON.encode(map, only: :visible)),
          options,
          map.keys.map(&:to_s).sort,
        ])
      RUBY

      assert_predicate status, :success?, error
      nested = { "visible" => 2, "hidden" => 3 }
      filtered = { "visible" => 1, "nested" => { "visible" => 2 } }

      assert_equal [
        { "visible" => 1, "hidden" => nil, "nested" => nested },
        filtered,
        filtered,
        { "visible" => 1 },
        filtered,
        { "visible" => 1 },
        { "only" => %w[visible nested] },
        %w[hidden nested visible]
      ], JSON.parse(output)
    end
  end
end
