# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/oj"

module Farce
  class OjTests < Test
    def test_primitive_encoding_and_mode_contracts
      values = [Vector.new([1, false, nil]), Map.new({ "x" => 2 }), Set.new([3]),
                Counter.new(2).increment(3), Flag.new(true), Atom.new, Atom.new(false)]
      primitives = [[1, false, nil], { "x" => 2 }, [3], 5, true, nil, false]
      values.zip(primitives).each do |value, primitive|
        assert_equal primitive.to_json(indent: "  "), value.to_json(indent: "  ")
        assert_equal [primitive], ::Oj.strict_load("[#{value.to_json}]")
        assert_equal [primitive], ::Oj.strict_load("[#{::Oj.to_json(value)}]")
        assert_raises(TypeError) { ::Oj.dump(value, mode: :strict) }
        assert_equal "null", ::Oj.dump(value, mode: :null)
      end
    end

    def test_object_mode_restores_nested_types_and_independent_storage
      source = Vector.new([Map.new({ "count" => Counter.new(2).increment(3) }), Atom.new(Flag.new(true)),
                           Set.new([1, 2])])
      copy = ::Oj.load(::Oj.dump(source))

      assert_instance_of Vector, copy
      assert_instance_of Map, copy[0]
      assert_instance_of Counter, copy[0]["count"]
      assert_equal 5, copy[0]["count"].value
      assert_equal 2, copy[0]["count"].reset.value
      assert_equal 5, source[0]["count"].value
      assert_instance_of Atom, copy[1]
      assert_instance_of Flag, copy[1].value
      assert copy[1].value.value
      assert_instance_of Set, copy[2]
      assert_equal [1, 2], copy[2].to_a.sort
      copy << 42
      copy[0]["extra"] = true

      assert_equal 3, source.size
      refute source[0].key?("extra")
    end

    def test_explicit_variant_registration_and_reconstruction_options
      Oj.register_type(Local::Counter, scope: :fiber)
      Oj.register_type(LRUMap, max_size: 2)
      Oj.register_type(Unshared::Vector)
      counter = ::Oj.load(::Oj.dump(Local::Counter.new(3, scope: :thread).increment(4)))
      map = ::Oj.load(::Oj.dump(LRUMap.new({ a: 1 }, max_size: 5)))
      vector = ::Oj.load(::Oj.dump(Unshared::Vector.new([false, nil])))

      assert_equal :fiber, counter.scope
      assert_equal 7, counter.value
      assert_equal 3, counter.reset.value
      assert_equal 2, map.max_size
      assert_equal({ a: 1 }, map.to_h)
      assert_instance_of Unshared::Vector, vector
      assert_equal [false, nil], vector.to_a
      assert_raises(ArgumentError) { Oj.register_type(String) }
      assert_raises(ArgumentError) { Oj.register_type(Class.new(Vector)) }
      assert_raises(ArgumentError) { Oj.register_type(Abstract::Vector) }
    end

    def test_concurrent_ractor_round_trips_after_registration
      return unless Internal.native_ractors?

      workers = Array.new(3) do
        Ractor.new do
          30.times do
            source = Farce::Vector.new([Farce::Counter.new(2).increment(3), Farce::Flag.new(true)])
            copy = ::Oj.load(::Oj.dump(source))
            raise "wrong values" unless copy[0].value == 5 && copy[0].reset.value == 2 && copy[1].value
          end
          begin
            Farce::Oj.register_type(Farce::Local::Counter)
            raise "registration outside main Ractor accepted"
          rescue Ractor::IsolationError
            true
          end
        end
      end

      workers.each { assert(it.respond_to?(:value) ? it.value : it.take) }
    end

    def test_load_paths_and_mimic_json
      [
        'require "farce"; require "oj"',
        'require "oj"; require "farce"',
        'require "farce"; require "oj/json"',
        'require "oj/json"; require "farce"',
        'require "farce"; require "oj"; Oj.mimic_JSON',
        'require "oj"; Oj.mimic_JSON; require "farce"',
        'require "json"; require "farce"; require "oj"',
        'require "farce"; require "oj"; require "json"'
      ].each do |setup|
        output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
          #{setup}
          source = Farce::Vector.new([Farce::Counter.new(3), Farce::Flag.new(true), Farce::Atom.new(nil)])
          raise "wrong encoding" unless Oj.strict_load(source.to_json) == [3, true, nil]
          if defined?(JSON) && JSON.respond_to?(:generate)
            raise "JSON failed" unless Oj.strict_load(JSON.generate(source)) == [3, true, nil]
          end
          raise "Oj integration missing" unless Farce::Integrations.load_active.include?(:oj)
          puts "ok"
        RUBY

        assert_predicate status, :success?, "#{setup}\n#{output}\n#{error}"
        assert_equal "ok\n", output
      end
    end

    def test_compat_and_custom_modes_with_oj_as_json_replacement
      output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
        require "farce"
        require "oj"
        Oj.mimic_JSON
        value = Farce::Vector.new([Farce::Counter.new(3), Farce::Flag.new(true), Farce::Atom.new(nil)])
        [:compat, :custom].each do |mode|
          encoded = Oj.dump(value, mode: mode, use_to_json: true)
          raise "incorrect contents" unless Oj.strict_load(encoded) == [3, true, nil]
        end
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end

    def test_loading_preserves_oj_defaults_and_require_results
      output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
        require "oj"
        original = Oj.default_options
        require "farce"
        raise "defaults changed" unless Oj.default_options == original
        raise "require return changed" if require "oj"
        result = Oj.mimic_JSON
        raise "mimic return changed" unless result.equal?(JSON)
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end
  end
end
