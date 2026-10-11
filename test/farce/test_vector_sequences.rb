# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestVectorSequences < Test
    VECTOR_CLASSES = [Vector, Strict::Vector, Unshared::Vector, Local::Vector].freeze

    def run(...) = Timeout.timeout(20) { super }

    def test_flatten_matches_array_depth_and_recursive_behavior
      source = Ractor.make_shareable([1, [2, [3]], [], nil])
      VECTOR_CLASSES.each do |klass|
        [-1, 0, 1, 2, 20].each do |depth|
          vector = klass.new(source)
          flattened = vector.flatten(depth)

          assert_instance_of klass, flattened
          assert_equal source.flatten(depth), flattened.to_a
          result = vector.flatten!(depth)
          depth.zero? ? assert_nil(result) : assert_same(vector, result)

          assert_equal source.flatten(depth), vector.to_a
        end
        nested = klass.new([2, 3])
        vector = klass.new([1, nested])

        assert_equal [1, 2, 3], vector.flatten.to_a
        vector = klass.new
        vector << vector

        assert_raises(ArgumentError) { vector.flatten }
        assert_raises(ArgumentError) { vector.flatten! }
        assert_same vector, vector[0]
        assert_equal [vector], vector.flatten(1).to_a
      end
    end

    def test_flatten_accepts_array_coercion_and_rejects_recursive_arrays
      array = []
      array << array
      vector = Unshared::Vector.new([array])

      assert_raises(ArgumentError) { vector.flatten }
      assert_same array, vector[0]
      coercible = Object.new
      coercible.define_singleton_method(:to_ary) { [1, [2]] }
      vector = Unshared::Vector.new([coercible])

      assert_equal [1, 2], vector.flatten.to_a
    end

    def test_transpose_and_product_produce_vectors
      VECTOR_CLASSES.each do |klass|
        rows = Ractor.make_shareable([[1, 2], [3, 4]])
        vector = klass.new(rows)
        transposed = vector.transpose

        assert_instance_of klass, transposed
        assert_equal [[1, 3], [2, 4]], transposed.to_a.map(&:to_a)
        transposed.each { assert_instance_of klass, it }
        assert_raises(IndexError) { klass.new(Ractor.make_shareable([[1], [2, 3]])).transpose }
        vector = klass.new([1, 2])
        product = vector.product([3, 4], klass.new([5]))

        assert_instance_of klass, product
        assert_equal [1, 2].product([3, 4], [5]), product.to_a.map(&:to_a)
        product.each { assert_instance_of klass, it }
        visited = []

        assert_same vector, vector.product([3, 4]) { visited << it.to_a }
        assert_equal [1, 2].product([3, 4]), visited
        assert_equal [[1], [2]], vector.product.to_a.map(&:to_a)
        assert_empty vector.product([])
        assert_empty klass.new.transpose
      end
    end

    def test_combinatorial_methods_return_sized_lazy_enumerators_and_vector_tuples
      VECTOR_CLASSES.each do |klass|
        %i[combination repeated_combination permutation repeated_permutation].each do |method|
          [-1, 0, 1, 2, 4].each do |count|
            vector = klass.new([1, 2, 3])
            expected = [1, 2, 3].public_send(method, count)
            enumerator = vector.public_send(method, count)

            assert_instance_of Enumerator, enumerator
            assert_equal expected.size, enumerator.size
            actual = enumerator.to_a
            actual.each { assert_instance_of klass, it }

            assert_equal expected.to_a, actual.map(&:to_a)
            yielded = []

            assert_same vector, vector.public_send(method, count) { yielded << it.to_a }
            assert_equal expected.to_a, yielded
          end
        end
        vector = klass.new([1, 2])

        assert_equal [1, 2].permutation.to_a, vector.permutation.map(&:to_a)
      end
    end

    def test_flatten_handles_deep_nesting_without_using_the_ruby_call_stack
      nested = 1
      5_000.times { nested = [nested] }
      vector = Unshared::Vector.new([nested])

      assert_equal [1], vector.flatten.to_a
    end

    def test_sequence_operations_preserve_managed_source_descendants
      %i[copy local move].each do |mode|
        vector = Vector.new([[+"a", +"b"]], mode:)
        row = vector[0]
        flattened = vector.flatten
        transposed = vector.transpose

        assert_equal %w[a b], flattened.to_a
        assert_equal [["a"], ["b"]], transposed.to_a.map(&:to_a)
        assert_equal %w[a b], row
        assert_equal %w[a b], vector[0]
        vector = Vector.new([+"a", +"b"], mode:)
        peer = vector.reverse
        original = vector.to_a
        product = vector.product(peer)

        product.each do |tuple|
          tuple.each { |value| assert(original.any? { it.equal?(value) }) }
        end

        assert_equal %w[a b], vector.to_a
      end
    end

    def test_identity_equality_and_hashing_are_preserved
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2])
        peer = klass.new([1, 2])
        original_hash = vector.hash
        table = { vector => :found }

        refute_equal vector, peer
        refute_equal vector, [1, 2]
        refute vector.eql?(peer)
        assert vector.eql?(vector)
        vector << 3

        assert_equal original_hash, vector.hash
        assert_equal :found, table[vector]
        refute table.key?(peer)
      end
    end

    def test_lexicographic_comparison
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2])
        peer = klass.new([1, 2])

        assert_equal 0, vector <=> peer
        assert_equal(-1, vector <=> [1, 3])
        assert_equal 1, vector <=> [1]
        assert_nil vector <=> Object.new
      end
    end

    def test_recursive_lexicographic_comparison
      VECTOR_CLASSES.each do |klass|
        left = klass.new
        right = klass.new
        left << left
        right << right

        assert_equal 0, left <=> right
        right << 1

        assert_equal(-1, left <=> right)
      end
    end
  end
end
