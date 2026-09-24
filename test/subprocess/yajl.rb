# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/yajl"
require "stringio"

module Farce
  class YajlTests < Test
    def test_nested_primitive_encoding_and_streaming
      value = Vector.new([Map.new({ "count" => Counter.new(2).increment(3) }), Atom.new(Flag.new(true)), Set.new([1])])
      expected = [{ "count" => 5 }, true, [1]]

      assert_equal expected, ::Yajl::Parser.parse(value.to_json)
      assert_equal expected, ::Yajl::Parser.parse(::Yajl.dump(value))
      assert_equal expected, ::Yajl::Parser.parse(::Yajl::Encoder.new.encode(value))
      stream = StringIO.new
      ::Yajl::Encoder.encode(value, stream)

      assert_equal expected, ::Yajl::Parser.parse(stream.string)
      chunks = []
      ::Yajl::Encoder.encode(value) { chunks << it }

      assert_equal expected, ::Yajl::Parser.parse(chunks.join)
      assert_equal 3, value.size
    end

    def test_variants_and_scalar_states
      [Strict::Vector, Unshared::Vector, Local::Vector].each do |klass|
        assert_equal [1, false, nil], ::Yajl::Parser.parse(klass.new([1, false, nil]).to_json)
      end
      [Local::Counter.new(7), Local::Flag.new(false), Local::Atom.new(nil),
       Atom.new("text"), Atom.new(false)].zip([7, false, nil, "text", false]).each do |value, expected|
        assert_equal [expected], ::Yajl::Parser.parse("[#{value.to_json}]")
      end
    end

    def test_load_orders_and_json_compatibility_shim
      [
        'require "farce"; require "yajl"',
        'require "yajl"; require "farce"',
        'require "farce"; require "yajl/json_gem"',
        'require "yajl/json_gem"; require "farce"',
        'require "json"; require "farce"; require "yajl"',
        'require "farce"; require "yajl"; require "json"'
      ].each do |setup|
        output, error, status = ruby_isolated(<<~RUBY, timeout: 60)
          #{setup}
          value = Farce::Vector.new([Farce::Counter.new(3), Farce::Flag.new(true), Farce::Atom.new(nil)])
          expected = [3, true, nil]
          raise "wrong encoding" unless Yajl::Parser.parse(value.to_json) == expected
          raise "dump failed" unless Yajl::Parser.parse(Yajl.dump(value)) == expected
          if defined?(JSON) && JSON.respond_to?(:generate)
            raise "JSON failed" unless Yajl::Parser.parse(JSON.generate(value)) == expected
          end
          raise "Yajl integration missing" unless Farce::Integrations.load_active.include?(:yajl)
          puts "ok"
        RUBY

        assert_predicate status, :success?, "#{setup}\n#{output}\n#{error}"
        assert_equal "ok\n", output
      end
    end

    def test_encoding_in_independent_threads
      threads = Array.new(3) do
        Thread.new do
          30.times do
            source = Vector.new([Counter.new(3), Flag.new(true)])
            raise "incorrect contents" unless ::Yajl::Parser.parse(::Yajl.dump(source)) == [3, true]
          end
          true
        end
      end

      threads.each { assert it.value }
    end
  end
end
