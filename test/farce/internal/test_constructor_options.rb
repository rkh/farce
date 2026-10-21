# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"

module Farce
  module Internal
    class TestConstructorOptions < Test
      def test_keyword_values_preserve_caller_options
        options = { compare_by_identity: true }.freeze
        vector = Vector.new([1], **options)
        map = StrictMap.new({ 1 => 2 }, **options)

        assert_predicate vector, :compare_by_identity?
        assert_predicate map, :compare_keys_by_identity?
        assert_predicate map, :compare_values_by_identity?
        assert_equal({ compare_by_identity: true }, options)
        assert_equal 1, vector[0]
        assert_equal 2, map[1]
      end

      def test_unknown_keywords_preserve_caller_options_and_error
        options = { compare_by_identity: true, unexpected: false }.freeze
        [[Vector, [1]], [StrictMap, { 1 => 2 }]].each do |type, source|
          error = assert_raises(ArgumentError) { type.new(source, **options) }

          assert_equal "unknown keyword: :unexpected", error.message
          assert_equal({ compare_by_identity: true, unexpected: false }, options)
        end
      end

      def test_positional_hash_is_an_initial_mapping
        source = { compare_by_identity: 1 }.freeze
        map = StrictMap.new(source)

        refute_predicate map, :compare_keys_by_identity?
        assert_equal 1, map[:compare_by_identity]
        assert_raises(TypeError) { Vector.new(source) }
      end

      def test_too_many_positional_arguments_count_keywords_separately
        [[Vector, [1]], [StrictMap, { 1 => 2 }]].each do |type, source|
          error = assert_raises(ArgumentError) { type.new(source, source, compare_by_identity: true) }

          assert_equal "wrong number of arguments (given 2, expected 0..1)", error.message
        end
      end

      def test_empty_keywords_preserve_defaults
        vector = Vector.new(**{})
        map = StrictMap.new(**{})

        assert_equal 0, vector.size
        assert_equal 0, map.size
        refute_predicate vector, :compare_by_identity?
        refute_predicate map, :compare_keys_by_identity?
      end
    end
  end
end
