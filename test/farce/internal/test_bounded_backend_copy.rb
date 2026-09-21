# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "farce/engine/shared/portable_bounded_map"

module Farce
  module Internal
    class TestBoundedBackendCopy < Test
      class MutableHashKey
        attr_accessor :fail_hash

        def hash
          raise "hash callback during copy" if fail_hash
          19
        end

        def eql?(other) = equal?(other)
      end

      def test_lru_copy_keeps_recency_and_independent_storage
        lru_types.each do |type|
          original = type.new(max_size: 3)
          original[:a] = :a
          original[:b] = :b
          original[:c] = :c
          original[:a]
          copy = original.dup

          assert_equal 3, copy.max_size
          assert_equal %i[b b], copy.shift
          assert_equal %i[b b], original.shift
          copy[:d] = :d

          refute original.key?(:d)
          original[:e] = :e

          refute copy.key?(:e)
        end
      end

      def test_lfu_copy_keeps_frequency_and_tie_recency
        lfu_types.each do |type|
          original = type.new(max_size: 3)
          original[:a] = :a
          original[:b] = :b
          original[:c] = :c
          original[:a]
          original[:b]
          copy = original.dup

          copy[:a]
          copy[:d] = :d

          refute copy.key?(:c)
          assert_equal %i[d d], copy.shift
          assert_equal %i[b b], copy.shift
          assert_equal %i[a a], copy.shift
          assert_equal %i[c c], original.shift
          assert_equal %i[a a], original.shift
          assert_equal %i[b b], original.shift
        end
      end

      def test_copy_shares_values_and_preserves_comparison
        [PortableLRUMap, PortableLFUMap, Internal::LRUMap, Internal::LFUMap].uniq.each do |type|
          key = Object.new
          value = []
          original = type.new(max_size: 2, compare_keys_by_identity: true, compare_values_by_identity: true)
          original[key] = value
          copy = original.dup

          assert_predicate copy, :compare_keys_by_identity?
          assert_predicate copy, :compare_values_by_identity?
          assert_same value, copy[key]
          assert_nil copy[Object.new]
          copy.max_size = 1

          assert_equal 2, original.max_size
        end
      end

      def test_copy_does_not_call_key_methods
        [PortableLRUMap, PortableLFUMap, Internal::LRUMap, Internal::LFUMap].uniq.each do |type|
          key = MutableHashKey.new
          original = type.new(max_size: 2)
          original[key] = :value
          key.fail_hash = true

          copy = original.dup

          assert_equal [[key, :value]], copy.each.to_a
        end
      end

      def test_native_strict_copy_remains_shareable
        return unless RUBY_ENGINE == "ruby"

        [Internal::ShareableLRUMap, Internal::ShareableLFUMap].each do |type|
          original = type.new({ key: :value }, max_size: 2)
          copy = original.dup

          assert Ractor.shareable?(copy)
          refute_predicate copy, :frozen?
          assert_equal :value, copy[:key]
          assert_equal :added, copy[:added] = :added
          refute original.key?(:added)
        end
      end

      private

      def lru_types
        types = [PortableLRUMap, PortableStrictLRUMap]
        types.push(Internal::LRUMap, Internal::ShareableLRUMap)
        types.uniq
      end

      def lfu_types
        types = [PortableLFUMap, PortableStrictLFUMap]
        types.push(Internal::LFUMap, Internal::ShareableLFUMap)
        types.uniq
      end
    end
  end
end
