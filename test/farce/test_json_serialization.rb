# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "json"

module Farce
  class TestJsonSerialization < Test
    def test_json_methods_activate_only_after_json_is_loaded
      ["require", "Kernel.require"].each do |loader|
        # Coverage itself requires JSON before the probe starts.
        output, error, status = ruby_isolated(<<~RUBY, coverage: false)
          require "farce"
          values = [Farce::Map.new, Farce::Vector.new, Farce::Set.new,
                    Farce::Counter.new, Farce::Flag.new, Farce::Atom.new]
          raise "JSON loaded by core" if defined?(JSON)
          raise "JSON methods exposed by core" if values.any? { it.respond_to?(:to_json) }
          raise "first require returned false" unless #{loader}("json")
          raise "second require returned true" if #{loader}("json")
          raise "JSON integration missing" unless Farce::Integrations.load_active.include?(:json)
          puts JSON.generate(values)
        RUBY

        assert_predicate status, :success?, error
        assert_equal [{}, [], [], 0, false, nil], JSON.parse(output)
      end
    end

    def test_explicit_json_integration_loads_its_dependency
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce/integrations/json"
        puts Farce::Vector.new([Farce::Flag.new(true)]).to_json
      RUBY

      assert_predicate status, :success?, error
      assert_equal [true], JSON.parse(output)
    end

    def test_nested_values_and_collections_use_json_primitives
      [Vector, Strict::Vector, Unshared::Vector, Local::Vector].each do |type|
        vector = type.new([Counter.new(3), Flag.new(true), Atom.new(false), Map.new({ "x" => 1 })])
        expected = [3, true, false, { "x" => 1 }]

        assert_equal expected, JSON.parse(vector.to_json), type.name
        assert_equal expected, JSON.parse(JSON.generate(vector)), type.name
        assert_equal({ "items" => expected }, JSON.parse(JSON.generate({ items: vector })), type.name)
        assert_equal JSON.pretty_generate(expected), JSON.pretty_generate(vector), type.name
      end
    end

    def test_scalar_variants_delegate_to_the_current_value
      [Counter, Local::Counter, Flag, Local::Flag, Atom, Strict::Atom, Local::Atom,
       Strict::WeakAtom, Unshared::WeakAtom, Local::WeakAtom].each do |type|
        values = type <= Abstract::Flag ? [false, true] : [0, 7]
        values.each do |value|
          object = type.new(value)

          assert_equal value.to_json, object.to_json, type.name
          assert_equal [value], JSON.parse(JSON.generate([object])), type.name
        end
      end
      [nil, false, "text", [1, nil], { "x" => false }].each do |value|
        atom = Atom.new(value)

        assert_equal value.to_json, atom.to_json
        assert_equal [value], JSON.parse(JSON.generate([atom]))
      end
    end

    def test_json_encoding_in_another_ractor
      return unless Internal.native_ractors?

      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        require "json"
        vector = Farce::Vector.new([Farce::Counter.new(3), Farce::Flag.new(false), Farce::Atom.new(nil)])
        worker = Farce::Ractor.new(vector) { |values| JSON.generate({ items: values }) }
        puts(worker.respond_to?(:value) ? worker.value : worker.take)
      RUBY

      assert_predicate status, :success?, error
      assert_equal({ "items" => [3, false, nil] }, JSON.parse(output))
    end

    def test_json_load_order_and_active_support_encoding
      [%w[json farce], %w[farce json], %w[active_support/core_ext farce]].each do |order|
        output, error, status = ruby_isolated(<<~RUBY, coverage: false)
          require "active_support" if #{order.include?("active_support/core_ext")}
          #{order.map { "require #{it.inspect}" }.join("\n")}
          require "json"
          build = -> do
            Farce::Vector.new([Farce::Counter.new(3), Farce::Flag.new(true),
              Farce::Atom.new({ "visible" => 1, "hidden" => 2 }), Farce::Set.new([7])])
          end
          results = [JSON.parse(JSON.generate(build.call))]
          require "farce/integrations/active_support"
          vector = build.call
          results << JSON.parse(vector.to_json)
          results << JSON.parse(JSON.generate(vector))
          results << JSON.parse(ActiveSupport::JSON.encode(vector))
          results << JSON.parse(ActiveSupport::JSON.encode({ items: vector }))
          atom = Farce::Atom.new({ "visible" => 1, "hidden" => 2 })
          results << atom.as_json(only: "visible")
          results << JSON.parse(atom.to_json(only: "visible"))
          results << JSON.parse(ActiveSupport::JSON.encode(atom, only: "visible"))
          results << Farce::Counter.new(3).as_json.class.name
          puts JSON.generate(results)
        RUBY

        assert_predicate status, :success?, error
        expected = [3, true, { "visible" => 1, "hidden" => 2 }, [7]]

        assert_equal [expected, expected, expected, expected, { "items" => expected },
                      { "visible" => 1 }, { "visible" => 1 }, { "visible" => 1 }, "Integer"], JSON.parse(output)
      end
    end
  end
end
