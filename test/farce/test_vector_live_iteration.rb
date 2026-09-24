# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestVectorLiveIteration < Test
    include Helpers::InternalTestHelpers

    VECTOR_CLASSES = [Vector, Strict::Vector, Unshared::Vector, Local::Vector].freeze

    def test_iteration_observes_replacements_and_stops_after_clear
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2, 3])
        seen = []
        vector.each do |value|
          seen << value
          vector[1] = 20 if value == 1
          vector.clear if value == 20
        end

        assert_equal [1, 20], seen, klass.name
      end
    end

    def test_iteration_is_bounded_by_initial_length
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, nil, 3])
        seen = []
        vector.each do |value|
          seen << value
          vector << 4
          break if seen.length > 3
        end

        assert_equal [1, nil, 3], seen, klass.name
      end
    end

    def test_reverse_iteration_observes_shrinkage_without_missing_entries
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2, 3, 4])
        seen = []
        vector.reverse_each do |value|
          seen << value
          if value == 4
            3.times { vector.pop }
            vector[0] = 10
          end
        end

        assert_equal [4, 10], seen, klass.name
      end
    end

    def test_reverse_iteration_unwraps_managed_values
      %i[copy local move].each do |mode|
        vector = Vector.new([Object.new], mode:)

        assert_same vector[0], vector.reverse_each.first
      end
    end

    def test_writer_can_finish_while_iteration_block_is_running
      vector = Strict::Vector.new([1, 2, 3])
      ready = Queue.new
      done = Queue.new
      writer = Thread.new do
        ready.pop
        vector[1] = 20
        done << true
      end
      seen = []
      Timeout.timeout(5) do
        vector.each do |value|
          seen << value
          next unless value == 1
          ready << true
          done.pop
        end
        writer.join
      end

      assert_equal [1, 20, 3], seen
    ensure
      writer&.kill
      writer&.join
    end

    def test_fetch_preserves_nil_false_and_runs_fallback_outside_the_lock
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([nil, false])

        assert_nil vector.fetch(0, :absent)
        assert_same false, vector.fetch(-1, :absent)
        assert_equal :absent, vector.fetch(-3, :absent)
        assert_equal :written, vector.fetch(2) { vector[2] = :written }
        assert_equal :written, vector[2]
      end
    end

    def test_iteration_survives_buffer_growth_and_collection
      VECTOR_CLASSES.each do |klass|
        vector = klass.new(%w[first second])
        seen = []
        vector.each do |value|
          seen << value
          next unless seen.length == 1
          100.times { vector << "appended" }
          vector[1] = "replacement"
          GC.start
          GC.compact if GC.respond_to?(:compact)
        end

        assert_equal %w[first replacement], seen
      end
    end

    def test_iteration_can_resume_after_a_block_raises
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2])

        assert_raises(RuntimeError) { vector.each { raise "stop" if it == 1 } }
        assert_raises(RuntimeError) { vector.reverse_each { raise "stop" if it == 1 } }
        vector << 3

        assert_equal [1, 2, 3], vector.each.to_a
      end
    end

    def test_iteration_observes_a_write_from_another_ractor
      return unless Internal.native_ractors?

      vector = Strict::Vector.new([1, 2, 3])
      ready = Queue.new
      done = Queue.new
      writer = Ractor.new(vector, ready, done) do |shared, started, completed|
        started.pop
        shared[1] = 20
        completed << true
      end
      seen = []
      Timeout.timeout(5) do
        vector.each do |value|
          seen << value
          next unless value == 1
          ready << true
          done.pop
        end
        ractor_value(writer)
      end

      assert_equal [1, 20, 3], seen
    end

    def test_binary_search_matches_array_for_boolean_and_numeric_blocks
      VECTOR_CLASSES.each do |klass|
        [[], [1], [1, 3, 5, 7, 9]].each do |values|
          vector = klass.new(values)
          (0..10).each do |target|
            [->(value) { value >= target }, ->(value) { target <=> value }].each do |predicate|
              expected = values.bsearch(&predicate)
              actual = vector.bsearch(&predicate)
              expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
              expected_index = values.bsearch_index(&predicate)
              actual_index = vector.bsearch_index(&predicate)
              expected_index.nil? ? assert_nil(actual_index) : assert_equal(expected_index, actual_index)
            end
          end
        end
      end
    end

    def test_searches_and_streaming_operations_do_not_snapshot
      vector = Unshared::Vector.new([1, 2, 3])
      backend = vector.send(:internal_vector)
      backend.define_singleton_method(:snapshot) { raise "unexpected snapshot" }

      assert_predicate vector, :any?
      assert vector.all?(Integer)
      refute_predicate vector, :none?
      assert vector.one?(2)
      assert_equal(2, vector.find(&:even?))
      assert_equal 6, vector.sum
      assert_equal 6, vector.reduce(:+)
      assert_equal(3, vector.count(&:positive?))
      assert_equal 1, vector.count(2)
      assert_includes vector, 2
      assert_equal 1, vector.index(2)
      assert_equal 1, vector.rindex(2)
      assert_equal 2, vector.fetch(1)
      assert_equal :missing, vector.fetch(9, :missing)
      assert_raises(IndexError) { vector.fetch(9) }
      assert_equal(2, vector.bsearch { it >= 2 })
      assert_equal(1, vector.bsearch_index { it >= 2 })
      assert_equal 1, vector.min
      assert_equal 3, vector.max
      assert_equal(3, vector.min_by(&:-@))
      assert_equal(1, vector.max_by(&:-@))
      assert_equal [2, 3], vector.select { it > 1 }.to_a
      assert_equal [1], vector.reject { it > 1 }.to_a
      assert_equal [1, 2], vector.take_while { it < 3 }.to_a
      assert_equal [3], vector.drop_while { it < 3 }.to_a
      assert_equal [[1, 2], [3]], vector.each_slice(2).map(&:to_a)
      assert_equal [[1, 2], [2, 3]], vector.each_cons(2).map(&:to_a)
      assert_equal [1, 3], vector.partition(&:odd?)[0].to_a
      assert_equal [1, 3], vector.group_by(&:odd?)[true].to_a
    end
  end
end
