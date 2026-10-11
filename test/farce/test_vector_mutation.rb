# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestVectorMutation < Test
    include Helpers::InternalTestHelpers

    VECTOR_CLASSES = [Vector, Strict::Vector, Unshared::Vector, Local::Vector].freeze

    def run(...) = Timeout.timeout(20) { super }

    def test_mutators_match_array_results_and_contents
      operations = [
        ->(v) { v.map! { it * 2 } }, ->(v) { v.collect! { it + 1 } },
        ->(v) { v.keep_if(&:odd?) }, ->(v) { v.select!(&:odd?) },
        ->(v) { v.filter!(&:even?) }, ->(v) { v.reject!(&:odd?) },
        lambda(&:uniq!), ->(v) { v.uniq! { it % 2 } },
        lambda(&:reverse!), ->(v) { v.rotate!(-1) },
        ->(v) { v.shuffle!(random: Random.new(17)) }, lambda(&:sort!),
        ->(v) { v.sort! { |left, right| right <=> left } }, ->(v) { v.sort_by!(&:-@) },
        lambda(&:shift), ->(v) { v.shift(2) }, ->(v) { v.shift(20) },
        ->(v) { v.unshift(8, 9) }, ->(v) { v.prepend(8, 9) },
        ->(v) { v.insert(-2, 8, 9) }, ->(v) { v.insert(7, 8) },
        ->(v) { v.delete_at(-2) }, ->(v) { v.delete_at(20) },
        ->(v) { v.slice!(1, 2) }, ->(v) { v.slice!(1..2) }, ->(v) { v.slice!(1) },
        ->(v) { v.replace([8, 9]) }, ->(v) { v.replace(v) },
        ->(v) { v.fill(8) }, ->(v) { v.fill(8, 1, 2) }, ->(v) { v.fill(8, 2..5) },
        ->(v) { v.fill { it * 2 } }, ->(v) { v.fill(1, 2, &:-@) },
        ->(v) { v.fill(1..2, &:-@) }, ->(v) { v.push(8, 9) }, lambda(&:push),
        ->(v) { v.append(8, 9) }, ->(v) { v.pop(2) }, ->(v) { v.pop(20) }
      ]
      VECTOR_CLASSES.each do |klass|
        operations.each do |operation|
          array = [3, 1, 2, 1]
          vector = klass.new(array)
          expected = operation.call(array)
          actual = operation.call(vector)

          assert_equal array, vector.to_a, "#{klass}: #{operation.source_location}"
          if expected.equal?(array)
            assert_same vector, actual
          elsif expected.nil?
            assert_nil actual
          elsif expected.is_a?(Array)
            assert_instance_of klass, actual
            assert_equal expected, actual.to_a
          else
            assert_equal expected, actual
          end
        end
      end
    end

    def test_no_change_returns_and_empty_vectors
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2])

        assert_nil(vector.select! { true })
        assert_nil(vector.reject! { false })
        assert_nil vector.compact!
        assert_nil vector.uniq!
        assert_nil vector.flatten!
        assert_nil vector.flatten!(0)
        assert_same(vector, vector.keep_if { true })
        assert_same vector, vector.reverse!
        empty = klass.new

        assert_nil empty.shift
        assert_empty empty.shift(2)
        assert_empty empty.pop(2)
        assert_same empty, empty.push
        assert_same empty, empty.unshift
        assert_nil empty.compact!
        assert_nil empty.flatten!
        vector = klass.new([1, nil, false, nil])

        assert_same vector, vector.compact!
        assert_equal [1, false], vector.to_a
      end
    end

    def test_range_reads_and_slice_assignment
      operations = [
        ->(v) { v[1..2] }, ->(v) { v[1, 2] }, ->(v) { v[-2..] }, ->(v) { v[..1] },
        ->(v) { v[20, 2] }, ->(v) { v[1, -1] },
        ->(v) { v[1, 2] = [8, 9, 10] }, ->(v) { v[1..2] = [8] },
        ->(v) { v[1..2] = nil }, ->(v) { v[7, 0] = [8] },
        ->(v) { v[1..2] = v }
      ]
      VECTOR_CLASSES.each do |klass|
        operations.each do |operation|
          array = [1, 2, 3, 4]
          vector = klass.new(array)
          expected = operation.call(array)
          actual = operation.call(vector)

          assert_equal array, vector.to_a
          if expected.nil?
            assert_nil actual
          elsif actual.equal?(vector)
            assert_same array, expected
          elsif actual.is_a?(Abstract::Vector)
            assert_instance_of klass, actual
            assert_equal expected, actual.to_a
          else
            assert_equal expected, actual
          end
        end
      end
    end

    def test_block_mutators_have_sized_lazy_enumerators
      VECTOR_CLASSES.each do |klass|
        %i[map! collect! keep_if select! filter! reject! sort_by!].each do |method|
          vector = klass.new([1, 2, 3])
          enumerator = vector.public_send(method)

          assert_instance_of Enumerator, enumerator
          assert_equal 3, enumerator.size
          assert_equal [1, 2, 3], vector.to_a
          next if %i[select! filter! reject!].include?(method)

          assert_same(vector, enumerator.each do |value|
            method == :sort_by! ? -value : value.even?
          end)
        end
      end
    end

    def test_invalid_arguments_leave_contents_unchanged
      operations = [
        ->(v) { v.shift(-1) }, ->(v) { v.pop(-1) }, ->(v) { v.insert(-20, 8) },
        ->(v) { v.replace(8) }, lambda(&:fill), ->(v) { v.fill(8, 1, 2, 3) },
        ->(v) { v[1, -1] = [8] }, ->(v) { v[-20..1] = [8] },
        ->(v) { v.rotate!(Object.new) }, ->(v) { v.flatten(Object.new) }
      ]
      VECTOR_CLASSES.each do |klass|
        operations.each do |operation|
          array = [1, 2, 3]
          vector = klass.new(array)
          error = assert_raises(StandardError) { operation.call(array) }

          assert_raises(error.class) { operation.call(vector) }
          assert_equal [1, 2, 3], vector.to_a
          vector.push(4)

          assert_equal [1, 2, 3, 4], vector.to_a
        end
      end
    end

    def test_callback_failures_roll_back_and_release_reservations
      operations = [
        ->(v, block) { v.map!(&block) }, ->(v, block) { v.keep_if(&block) },
        ->(v, block) { v.select!(&block) }, ->(v, block) { v.reject!(&block) },
        ->(v, block) { v.sort_by!(&block) }, ->(v, block) { v.uniq!(&block) },
        ->(v, block) { v.fill(&block) }
      ]
      VECTOR_CLASSES.each do |klass|
        operations.each do |operation|
          vector = klass.new([3, 1, 2])
          visits = 0
          callback = lambda do |value|
            visits += 1
            raise "failed" if visits == 2
            value * 2
          end

          assert_raises(RuntimeError) { operation.call(vector, callback) }
          assert_equal [3, 1, 2], vector.to_a
          vector.push(4)

          assert_equal [3, 1, 2, 4], vector.to_a
        end
        vector = klass.new([3, 1, 2])

        assert_raises(RuntimeError) { vector.sort! { raise "comparison failed" } }
        assert_equal [3, 1, 2], vector.to_a
      end
    end

    def test_batch_update_stages_validates_and_detaches_storage
      [Internal::Vector, Internal::UnsharedVector].each do |klass|
        vector = klass.new([1, 2, 3])
        retained = nil

        assert(vector.batch_update do |values|
          retained = values
          values.replace([4, 5])

          assert_equal [1, 2, 3], vector.snapshot
        end)
        retained << 6

        assert_equal [4, 5], vector.snapshot
        assert_raises(RuntimeError) do
          vector.batch_update do |values|
            values.clear
            raise "failed"
          end
        end
        assert_equal [4, 5], vector.snapshot
        assert(vector.batch_update { it.concat((6..100).to_a) })
        assert_equal 97, vector.size
      end
      vector = Internal::Vector.new([1, 2])

      assert_raises(Ractor::IsolationError) { vector.batch_update { it << Unshared::Vector.new } }
      assert_equal [1, 2], vector.snapshot
      refute_respond_to Vector.new, :batch_update
    end

    def test_batch_reservations_allow_reads_and_time_out_other_writes
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([1, 2, 3])

        assert_same(vector, vector.map! do |value|
          assert_equal [1, 2, 3], vector.to_a
          refute vector.push(9, timeout: 0)
          refute vector.push(9, 10, timeout: 0)
          assert_nil vector.pop(2, timeout: 0)
          value * 2
        end)
        assert_equal [2, 4, 6], vector.to_a
      end
    end

    def test_managed_mutators_preserve_retained_values
      %i[copy local move].each do |mode|
        vector = Vector.new([+"b", +"a", +"b"], mode:)
        original = vector.to_a
        vector.reverse!
        vector.rotate!
        vector.sort!
        vector.sort_by!(&:length)
        vector.shuffle!(random: Random.new(17))
        vector.map! { it }
        vector.keep_if { true }
        vector.select! { true }
        vector.reject! { false }
        vector.compact!

        vector.to_a.each { |value| assert(original.any? { it.equal?(value) }) }
        removed = vector.pop(2)

        removed.each { |value| assert(original.any? { it.equal?(value) }) }
        vector.replace(removed)

        removed.each_with_index { |value, index| assert_same value, vector[index] }
      end
      vector = Vector.new([], mode: :copy)
      vector.push(+"a", +"b", mode: :local)

      assert_equal %w[a b], vector.to_a
    end

    def test_local_storage_and_identity_hash_remain_stable_after_mutation_and_copying
      vector = Local::Vector.new([1], scope: :fiber)
      original_hash = vector.hash
      vector << 2
      copy = vector.dup
      copy.unshift(0)

      assert_equal original_hash, vector.hash
      assert_equal [1, 2], vector.to_a
      assert_equal [0, 1, 2], copy.to_a
      assert_equal [1], Fiber.new { vector.to_a }.resume
      scoped_hash = Fiber.new do
        vector << 9
        vector.hash
      end.resume

      assert_equal original_hash, scoped_hash
      assert_equal [1, 2], vector.to_a
      restored = Marshal.load(Marshal.dump(vector))

      assert_equal [1, 2], restored.to_a
      restored << 3

      assert_equal [1, 2], vector.to_a
    end

    def test_frozen_vectors_reject_new_mutators
      VECTOR_CLASSES.reject { it == Unshared::Vector }.each do |klass|
        operations = [
          ->(v) { v.map! { it } }, ->(v) { v.keep_if { true } }, ->(v) { v.select! { true } },
          ->(v) { v.reject! { false } }, lambda(&:compact!), lambda(&:uniq!),
          lambda(&:reverse!), lambda(&:rotate!), lambda(&:shuffle!),
          lambda(&:sort!), ->(v) { v.sort_by! { it } }, lambda(&:flatten!),
          lambda(&:shift), lambda(&:unshift), ->(v) { v.insert(0) },
          ->(v) { v.delete_at(20) }, ->(v) { v.slice!(20) }, ->(v) { v.replace(v) },
          ->(v) { v.fill(1) }, lambda(&:push), ->(v) { v.pop(0) },
          ->(v) { v[0..0] = [1] }
        ]
        operations.each do |operation|
          vector = klass.new([1, 2]).freeze

          assert_raises(FrozenError) { operation.call(vector) }
          assert_equal [1, 2], vector.to_a
        end
      end
    end

    def test_gc_compaction_during_batches_and_mutation_from_another_ractor
      [Vector, Strict::Vector].each do |klass|
        vector = klass.new([3, 1, 2])

        assert_same(vector, vector.map! do |value|
          GC.compact if GC.respond_to?(:compact)
          value * 2
        end)
        worker = Ractor.new(vector) do |shared|
          shared.unshift(4)
          shared.sort!
          shared[1..2] = [9]
          shared.pop(2).to_a
        end

        assert_equal [9, 6], ractor_value(worker)
        assert_equal [2], vector.to_a
      end
    end

    def test_transactional_batch_mutations_and_lifetime_guards
      VECTOR_CLASSES.each do |klass|
        vector = klass.new([3, 1, 2])
        view = nil

        assert(Farce.transaction do |tx|
          view = tx[vector]
          view.unshift(4)
          view.sort!
          view.map! { it * 2 }
          view[1..2] = [9]
          view.push(10, 11)

          assert_equal [2, 9, 8, 10, 11], view.to_a
          assert_equal [3, 1, 2], vector.to_a
        end)
        assert_equal [2, 9, 8, 10, 11], vector.to_a
        %i[flatten transpose map! shift].each do |method|
          assert_raises(Transaction::ClosedError) { view.public_send(method) }
        end
        assert_raises(RuntimeError) do
          Farce.transaction do |tx|
            tx[vector].map! do |value|
              raise "failed" if value == 9
              value * 2
            end
          end
        end
        assert_equal [2, 9, 8, 10, 11], vector.to_a
      end
    end
  end
end
