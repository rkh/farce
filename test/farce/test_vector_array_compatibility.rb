# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestVectorArrayCompatibility < Test
    VECTOR_CLASSES = [Vector, Strict::Vector, Unshared::Vector, Local::Vector].freeze

    def run(...) = Timeout.timeout(15) { super }

    def test_bounded_iteration_and_explicit_array_conversion
      each_vector([1, 2, 3]) do |vector|
        enumerator = vector.each

        assert_instance_of Enumerator, enumerator
        assert_equal 3, enumerator.size
        vector << 4

        assert_equal [1, 2, 3, 4], enumerator.to_a

        visited = []
        result = vector.each do |value|
          visited << value
          vector << 5 if value == 1
        end

        assert_same vector, result
        assert_equal [1, 2, 3, 4], visited
        assert_equal [1, 2, 3, 4, 5], vector.to_a
        assert_instance_of Array, vector.to_a
        assert_instance_of Array, vector.deconstruct
        refute_same vector.to_a, vector.to_a
      end
    end

    def test_indexed_read_helpers
      each_vector([1, 2, 3, 4]) do |vector|
        assert_equal 4, vector.at(-1)
        assert_equal 2, vector.fetch(1)
        assert_equal :missing, vector.fetch(20, :missing)
        assert_equal 40, vector.fetch(20) { it * 2 }
        assert_raises(IndexError) { vector.fetch(20) }
        assert_equal 1, vector.first
        assert_equal 4, vector.last
        assert_vector_result(vector, [1, 2], vector.first(2))
        assert_vector_result(vector, [3, 4], vector.last(2))
        assert_vector_result(vector, [1, nil, 4], vector.values_at(0, 20, -1))
        assert_vector_result(vector, [1, 2, 4], vector.fetch_values(0, 1, 3))
        assert_vector_result(vector, [1, 4, 6], vector.fetch_values(0, 3, 5) { it + 1 })
      end
    end

    def test_coercible_indexes_are_reported_to_fallback_blocks_unchanged
      index = Object.new
      index.define_singleton_method(:to_int) { 20 }
      vector = Vector.new([1])
      observed = nil

      assert_same index, vector.fetch(index) { it }
      vector.fetch_values(index) do |missing_index|
        observed = missing_index
        :missing
      end

      assert_same index, observed
    end

    def test_query_helpers_and_enumerable_searches
      each_vector([1, 2, 2, nil, 3]) do |vector|
        assert_equal 5, vector.count
        assert_equal 2, vector.count(2)
        assert_equal(2, vector.count { it.is_a?(Integer) && it.odd? })
        assert_includes vector, 2
        refute_includes vector, 4
        assert_equal 1, vector.index(2)
        assert_equal 2, vector.rindex(2)
        assert_equal(4, vector.index { it == 3 })
        assert_equal(2, vector.find { it.even? if it })
        assert_equal(3, vector.rfind { it.is_a?(Integer) })
        assert vector.any?(nil)
        assert(vector.all? { it.nil? || it.is_a?(Integer) })
      end
    end

    def test_common_sequence_transforms_return_same_kind_vectors
      each_vector([3, 1, 2, 2, nil]) do |vector|
        assert_vector_result(vector, [6, 2, 4, 4, nil], vector.map { it * 2 if it })
        assert_vector_result(vector, [3, 2, 2], vector.select { it.is_a?(Integer) && it > 1 })
        assert_vector_result(vector, [1, nil], vector.reject { it.is_a?(Integer) && it > 1 })
        assert_vector_result(vector, [6, 2, 4, 4], vector.filter_map { it * 2 if it })
        assert_vector_result(vector, [3, 1, 2, 2], vector.compact)
        assert_vector_result(vector, [3, 1, 2, nil], vector.uniq)
        assert_vector_result(vector, [nil, 2, 2, 1, 3], vector.reverse)
        assert_vector_result(vector, [2, 2, nil, 3, 1], vector.rotate(2))
        assert_vector_result(vector, [1, 2, 2, 3], vector.compact.sort)
        assert_vector_result(vector, [nil, 1, 2, 2, 3], vector.sort_by { it || -1 })
        assert_vector_result(vector, [3, 1], vector.take(2))
        assert_vector_result(vector, [2, 2, nil], vector.drop(2))
        assert_vector_result(vector, [3], vector.take_while { it > 1 })
        assert_vector_result(vector, [1, 2, 2, nil], vector.drop_while { it > 1 })
      end
    end

    def test_set_and_concatenation_operations_return_vectors
      each_vector([1, 2, 2, 3]) do |vector|
        assert_vector_result(vector, [1, 2, 2, 3, 4], vector + [4])
        assert_vector_result(vector, [1, 3], vector - [2])
        assert_vector_result(vector, [2], vector & [2, 4])
        assert_vector_result(vector, [1, 2, 3, 4], vector | [2, 4])
        assert_vector_result(vector, [1, 3], vector.difference([2], [5]))
        assert_vector_result(vector, [2], vector.intersection([2, 4], [0, 2]))
        assert_vector_result(vector, [1, 2, 3, 4, 5], vector.union([2, 4], [5]))
        assert_vector_result(vector, [1, 2, 2, 3, 1, 2, 2, 3], vector * 2)
        assert_equal "1:2:2:3", vector * ":"
        assert vector.intersect?([5, 3])
        refute vector.intersect?([4, 5])
      end
    end

    def test_binary_search_and_pack
      each_vector([1, 3, 5, 7]) do |vector|
        assert_equal(5, vector.bsearch { it >= 4 })
        assert_equal(2, vector.bsearch_index { it >= 4 })
      end

      each_vector([65, 66]) { assert_equal "AB", it.pack("C*") }
    end

    def test_enumerable_results_follow_vector_return_policy
      each_vector([1, 2, 3, 4]) do |vector|
        assert_vector_result(vector, [nil, 2, nil, 4], vector.grep(Integer) { it if it.even? })
        assert_vector_result(vector, [1, 10, 2, 20, 3, 30, 4, 40], vector.flat_map { [it, it * 10] })

        partition = vector.partition(&:even?)

        assert_vector_result(vector, [[2, 4], [1, 3]], partition, nested: true)

        groups = vector.group_by(&:even?)

        assert_equal [false, true], groups.keys.sort_by(&:to_s)
        assert_vector_result(vector, [1, 3], groups.fetch(false))
        assert_vector_result(vector, [2, 4], groups.fetch(true))

        minmax = vector.minmax

        assert_vector_result(vector, [1, 4], minmax)
        assert_vector_result(vector, [1, 2], vector.min(2))
        assert_vector_result(vector, [4, 3], vector.max(2))
        assert_equal 1, vector.min(nil)
        assert_equal 4, vector.max(nil)
        assert_equal 1, vector.min_by(nil) { it }
        assert_equal 4, vector.max_by(nil) { it }
      end
    end

    def test_vector_windows_and_zip_rows
      each_vector([1, 2, 3]) do |vector|
        slices = vector.each_slice(2).to_a
        slices.each { assert_instance_of vector.class, it }

        assert_equal [[1, 2], [3]], slices.map(&:to_a)

        windows = []

        assert_same vector, vector.each_cons(2) { windows << it }
        windows.each { assert_instance_of vector.class, it }

        assert_equal [[1, 2], [2, 3]], windows.map(&:to_a)

        zipped = vector.zip(%i[a b c])

        assert_vector_result(vector, [[1, :a], [2, :b], [3, :c]], zipped, nested: true)
        assert_equal [[1, 4], [2, 5], [3, 6]], vector.zip(4..).to_a.map(&:to_a)
        assert_equal({ 1 => :a, 2 => :b, 3 => :c }, zipped.to_h)
        assert_equal({ 1 => 1, 2 => 4, 3 => 9 }, vector.to_h { [it, it * it] })
      end
    end

    def test_retained_managed_values_are_not_transferred_again
      %i[copy local move].each do |mode|
        vector = Vector.new([Object.new, Object.new], mode:)
        first = vector[0]
        retained = vector.select { true }
        mapped = vector.map { it }
        repeated = vector.flat_map { [it, it] }
        cross_mapped = vector.map { first }

        assert_same vector[0], retained[0]
        assert_same vector[0], mapped[0]
        assert_same vector[0], repeated[0]
        assert_same repeated[0], repeated[1]
        assert_same vector[0], cross_mapped[0]
        assert_same cross_mapped[0], cross_mapped[1]

        singleton = Vector.new([Object.new], mode:)
        original = singleton[0]
        minmax = singleton.minmax

        assert_same original, minmax[0]
        assert_same minmax[0], minmax[1]
        assert_same original, singleton[0]
      end
    end

    def test_concatenation_uses_one_source_snapshot
      vector = Vector.new([Object.new], mode: :local)
      original = vector[0]
      operand = Object.new
      operand.define_singleton_method(:to_ary) do
        vector.clear
        []
      end

      result = vector + operand

      assert_empty vector
      assert_same original, result[0]
    end

    def test_self_concatenation_and_zip_reuse_managed_storage
      %i[copy local move].each do |mode|
        vector = Vector.new([Object.new, Object.new], mode:)
        stored = vector.send(:internal_vector).snapshot
        concatenated = vector + vector
        zipped = vector.zip(vector)

        refute_predicate stored.last, :claimed? if mode == :move && Internal.native_ractors?

        assert_same vector[0], concatenated[0]
        assert_same concatenated[0], concatenated[2]
        assert_same vector[1], zipped[1][0]
        assert_same zipped[1][0], zipped[1][1]
      end
    end

    def test_zip_block_builds_rows_lazily
      return unless Internal.native_ractors?

      vector = Vector.new([Object.new, Object.new], mode: :move)
      stored = vector.send(:internal_vector).snapshot

      vector.zip([Object.new, Object.new]) { break } # rubocop:disable Lint/UnreachableLoop

      refute_predicate stored.first, :claimed?
      refute_predicate stored.last, :claimed?
    end

    def test_failed_mapping_does_not_claim_unvisited_move_values
      return unless Internal.native_ractors?

      vector = Vector.new([Object.new, Object.new], mode: :move)
      stored = vector.send(:internal_vector).snapshot

      assert_raises(RuntimeError) do
        vector.map do |value|
          raise "stop" if stored.first.claimed?
          value
        end
      end

      assert_predicate stored.first, :claimed?
      refute_predicate stored.last, :claimed?
    end

    def test_strict_mapping_rejects_new_unshareable_values_without_mutating_source
      return unless Internal.native_ractors?

      vector = Strict::Vector.new([1])

      assert_raises(Ractor::IsolationError) { vector.map { [] } }
      assert_equal [1], vector.to_a
    end

    def test_derived_shareable_vectors_work_across_ractors
      [Vector, Strict::Vector].each do |type|
        source = type.new([1, 2, 3])
        [source.reverse, source.map { it * 2 }].each do |derived|
          worker = Ractor.new(derived) { |value| value.to_a } # rubocop:disable Style/SymbolProc
          result = worker.respond_to?(:value) ? worker.value : worker.take

          assert_equal derived.to_a, result
        end
      end
    end

    def test_grouping_enumerators_yield_vectors
      each_vector([1, 1, 2, 3, 5]) do |vector|
        chunks = vector.chunk(&:odd?).to_a
        slices = vector.slice_before(&:odd?).to_a
        windows = vector.chunk_while { |left, right| left == right }.to_a

        chunks.each { assert_instance_of vector.class, it.last }
        slices.each { assert_instance_of vector.class, it }
        windows.each { assert_instance_of vector.class, it }
        chunk_values = chunks.map { it.last.to_a }

        assert_equal [[1, 1], [2], [3, 5]], chunk_values
        assert_equal [[1], [1, 2], [3], [5]], slices.map(&:to_a)
        assert_equal [[1, 1], [2], [3], [5]], windows.map(&:to_a)
      end
    end

    def test_grouping_methods_that_require_blocks_reject_missing_blocks
      vector = Vector.new([1, 2])

      assert_raises(ArgumentError) { vector.chunk_while }
      assert_raises(ArgumentError) { vector.slice_when }
    end

    def test_append_forwards_managed_options
      value = Object.new
      vector = Vector.new(mode: :local)

      assert_same vector, vector.append(value, mode: :local, timeout: 0)
      assert_same value, vector[0]
    end

    def test_array_queries_use_identity_as_an_equality_fast_path
      value = Float::NAN

      each_vector([value, [value, value].freeze]) do |vector|
        assert_includes vector, value
        assert_equal 0, vector.index(value)
        assert_equal 0, vector.rindex(value)
        assert_same value, vector.assoc(value).first
        assert_same value, vector.rassoc(value).last
      end
    end

    def test_fetch_values_delegates_large_index_handling_to_array
      vector = Vector.new([1])

      assert_raises(RangeError) { vector.fetch_values(10**100) { :missing } }
    end

    def test_structural_operations_do_not_claim_move_values
      return unless Internal.native_ractors?

      original = Object.new
      vector = Vector.new([original], mode: :move)
      stored = vector.send(:internal_vector).snapshot.fetch(0)

      refute_predicate stored, :claimed?

      empty = vector.take(0)
      reversed = vector.reverse

      assert_empty empty
      assert_instance_of Vector, reversed
      refute_predicate stored, :claimed?
      assert_same reversed[0], vector[0]
    end

    def test_derived_vectors_preserve_configuration_and_are_mutable
      value = Object.new
      vector = Vector.new([value], mode: :local, compare_by_identity: true)
      vector.freeze
      result = vector.select { true }

      assert_instance_of Vector, result
      assert_equal :local, result.mode
      assert_predicate result, :compare_by_identity?
      refute_predicate result, :frozen?
      assert_same result, result << :new

      local = Local::Vector.new([1, 2], scope: :fiber, compare_by_identity: true)
      local_result = local.reverse

      assert_instance_of Local::Vector, local_result
      assert_equal :fiber, local_result.scope
      assert_predicate local_result, :compare_by_identity?
      assert_equal [2, 1], Fiber.new { local_result.to_a }.resume
    end

    private

    def each_vector(values)
      VECTOR_CLASSES.each { yield it.new(values) }
    end

    def assert_vector_result(source, expected, actual, nested: false)
      assert_instance_of source.class, actual
      actual = actual.to_a
      actual = actual.map(&:to_a) if nested

      assert_equal expected, actual
    end
  end
end
