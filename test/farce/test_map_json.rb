# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "json"

module Farce
  class TestMapJson < Test
    def test_plain_farce_does_not_define_as_json
      refute_respond_to({}, :as_json)
      [Map, Strict::Map, Unshared::Map, Local::Map, WeakKeyMap, Strict::WeakValueMap,
       Strict::WeakMap, TreeMap, LRUMap, LFUMap].each do |type|
        options = type < Abstract::BoundedMap ? { max_size: 3 } : {}
        map = type.new({ a: 1, b: nil, c: false }, **options)

        refute_respond_to map, :as_json
        assert_equal({ "a" => 1, "b" => nil, "c" => false }, JSON.parse(map.to_json))
      end
    end

    def test_json_serializes_unwrapped_values_and_nested_maps
      nested = Map.new({ enabled: false })
      map = Map.new({ items: [1, nil], nested: }, mode: :copy)
      expected = { "items" => [1, nil], "nested" => { "enabled" => false } }

      assert_equal expected, JSON.parse(map.to_json)
      assert_equal [expected], JSON.parse(JSON.generate([map]))
      assert_equal JSON.pretty_generate(map.to_h), JSON.pretty_generate(map)
      assert_equal({}, JSON.parse(Map.new.to_json))
    end

    def test_active_support_conversion_and_json_options
      [[], %w[farce active_support/json], %w[active_support/json farce]].each do |preload|
        output, error, status = ruby_isolated(<<~RUBY)
          #{preload.map { "require #{it.inspect}" }.join("\n")}
          require "farce/integrations/active_support"

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

    def test_integration_extends_existing_map_variants
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        types = [Farce::Map, Farce::Strict::Map, Farce::Unshared::Map, Farce::Local::Map,
                 Farce::WeakKeyMap, Farce::Strict::WeakValueMap, Farce::Strict::WeakMap,
                 Farce::TreeMap, Farce::LRUMap, Farce::LFUMap]
        maps = types.map do |type|
          options = type < Farce::Abstract::BoundedMap ? { max_size: 3 } : {}
          type.new({ a: 1, b: nil, c: false }, **options)
        end
        require "farce/integrations/active_support"
        puts JSON.generate(maps.map do |map|
          converted = map.as_json
          selected = map.as_json(only: [:a, :c])
          converted.clear
          [selected, map.to_h]
        end)
      RUBY

      assert_predicate status, :success?, error
      assert_equal Array.new(10) { [{ "a" => 1, "c" => false }, { "a" => 1, "b" => nil, "c" => false }] },
        JSON.parse(output)
    end
  end
end
