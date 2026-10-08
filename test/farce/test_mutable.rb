# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestMutable < Test
    include Helpers::InternalTestHelpers

    class Payload
      attr_reader :count

      def initialize(count, offset: 0, &block)
        @count = block ? block.call(count + offset) : count + offset
      end

      def read(amount, offset:, &block) = block.call(count + amount + offset)

      def add(amount, offset:, &block)
        @count += block.call(amount + offset)
        self
      end

      def fail_after_write
        @count += 1
        raise ArgumentError, "mutation failed"
      end
    end

    def test_initialization_copies_and_freezes_the_snapshot
      source = [1, 2]
      mutable = Mutable.new(source)
      snapshot = Mutable.deref(mutable)
      source << 3

      assert_equal [1, 2], snapshot
      refute_same source, snapshot
      assert_predicate snapshot, :frozen?
      refute_predicate source, :frozen?
      refute_predicate mutable, :frozen?
      assert Ractor.shareable?(mutable)
    end

    def test_strings_are_snapshotted_without_freezing_the_source
      source = +"first"
      mutable = Mutable.new(source)
      snapshot = Mutable.deref(mutable)
      source.replace("second")

      assert_equal "first", mutable.to_s
      assert_predicate snapshot, :frozen?
      refute_predicate source, :frozen?
      assert_same mutable, mutable.replace("third")
      assert_equal "first", snapshot
      assert_equal "third", Mutable.deref(mutable)
      assert_equal "second", source
    end

    def test_reuses_an_already_frozen_snapshot
      source = [1, 2].freeze
      mutable = Mutable.new(source)

      assert_same source, Mutable.deref(mutable)
      assert_same mutable, mutable.push(3)
      assert_equal [1, 2], source
      assert_equal [1, 2, 3], Mutable.deref(mutable)
    end

    def test_deref_leaves_other_objects_unchanged
      assert_nil Mutable.deref(nil)
      [false, :value, Object.new, BasicObject.new].each do |value|
        assert_same value, Mutable.deref(value)
      end
    end

    def test_nonmutating_calls_reuse_the_current_snapshot
      mutable = Mutable.new([1, 2])
      snapshot = Mutable.deref(mutable)

      assert_equal 3, mutable.sum
      assert_equal([2, 4], mutable.map { it * 2 })
      assert_same snapshot, Mutable.deref(mutable)
      assert_respond_to mutable, :push
      refute_respond_to mutable, :missing_method
      assert_raises(NoMethodError) { mutable.missing_method }
    end

    def test_forwards_arguments_keywords_and_blocks_to_readers_and_mutators
      source = Payload.new(1)
      mutable = Mutable.new(source)

      assert_equal 14, mutable.read(3, offset: 3) { it * 2 }
      assert_same mutable, mutable.add(2, offset: 3) { it * 2 }
      assert_equal 11, mutable.count
      assert_equal 1, source.count
      assert_predicate Mutable.deref(mutable), :frozen?
    end

    # Keep the wrapper as the operator receiver, including for nil and false.
    # rubocop:disable-next Minitest/AssertEqual, Minitest/RefuteEqual
    def test_delegates_equality_inequality_and_negation
      mutable = Mutable.new([1])

      assert_operator mutable, :==, [1]
      refute_operator mutable, :==, [2]
      assert_operator mutable, :!=, [2]
      refute_operator mutable, :!=, [1]
      refute_predicate mutable, :!
      [nil, false].each do |value|
        assert_predicate Mutable.new(value), :!
      end
    end

    # kind_of? is delegated, so exercise the wrapper's own is_a? method.
    # rubocop:disable Minitest/AssertKindOf, Minitest/RefuteKindOf
    def test_is_a_recognizes_the_wrapper_and_the_target
      mutable = Mutable.new([1])

      assert mutable.is_a?(Mutable)
      assert mutable.is_a?(Array)
      refute mutable.is_a?(Hash)
    end

    # rubocop:enable Minitest/AssertKindOf, Minitest/RefuteKindOf

    def test_instance_eval_and_instance_exec_delegate_to_the_target
      mutable = Mutable.new([1, 2])

      assert_same(Mutable.deref(mutable), mutable.instance_eval { self })
      assert_equal 7, mutable.instance_exec(4) { sum + it }
      assert_equal 3, mutable.instance_eval("sum", __FILE__, __LINE__)
      assert_same(mutable, mutable.instance_exec(3) { push(it) })
      assert_equal [1, 2, 3], Mutable.deref(mutable)
    end

    def test_mutations_replace_the_snapshot_and_preserve_return_values
      mutable = Mutable.new([1, 2])
      snapshot = Mutable.deref(mutable)

      assert_same mutable, mutable.push(3)
      refute_same snapshot, Mutable.deref(mutable)
      assert_equal [1, 2], snapshot
      assert_equal 3, mutable.pop
      assert_nil(mutable.reject! { false })
      assert_equal [1, 2], Mutable.deref(mutable)
      assert_predicate Mutable.deref(mutable), :frozen?
    end

    def test_failed_mutation_keeps_the_snapshot_and_releases_the_update
      mutable = Mutable.new(Payload.new(1))
      snapshot = Mutable.deref(mutable)
      error = assert_raises(ArgumentError) { mutable.fail_after_write }

      assert_equal "mutation failed", error.message
      assert_same snapshot, Mutable.deref(mutable)
      assert_equal 1, mutable.count
      mutable.add(2, offset: 0) { it }

      assert_equal 3, mutable.count
    end

    def test_rejects_nested_unshareable_values_without_freezing_them
      return unless Internal.native_ractors?
      child = []
      source = [child]

      assert_raises(Ractor::IsolationError) { Mutable.new(source) }
      refute_predicate source, :frozen?
      refute_predicate child, :frozen?
    end

    def test_failed_snapshot_publication_keeps_the_previous_value
      return unless Internal.native_ractors?
      mutable = Mutable.new([1])
      snapshot = Mutable.deref(mutable)
      child = []

      assert_raises(Ractor::IsolationError) { mutable.push(child) }
      assert_same snapshot, Mutable.deref(mutable)
      refute_predicate child, :frozen?
      assert_same mutable, mutable.push(2)
      assert_equal [1, 2], Mutable.deref(mutable)
    end

    def test_freezing_prevents_mutation_and_keeps_readers_available
      mutable = Mutable.new([1])

      assert_same mutable, mutable.freeze
      assert_predicate mutable, :frozen?
      assert_equal 1, mutable.sum
      assert_raises(FrozenError) { mutable.push(2) }
      assert_equal [1], Mutable.deref(mutable)
    end

    def test_freezing_during_a_mutation_prevents_publication
      mutable = Mutable.new([1])
      snapshot = Mutable.deref(mutable)

      assert_raises(FrozenError) do
        mutable.map! do |value|
          mutable.freeze
          value + 1
        end
      end
      assert_same snapshot, Mutable.deref(mutable)
      assert_predicate mutable, :frozen?
    end

    def test_copies_have_independent_storage_and_remain_shareable
      source = Mutable.new([1])
      [source.dup, source.clone, source.clone(freeze: false)].each do |copy|
        refute_same source, copy
        assert Ractor.shareable?(copy)
        refute_predicate copy, :frozen?
        copy.push(2)

        assert_equal [1, 2], Mutable.deref(copy)
        assert_equal [1], Mutable.deref(source)
        source.push(3)

        assert_equal [1, 2], Mutable.deref(copy)
        source.pop
      end
    end

    def test_copy_operations_preserve_logical_freeze_semantics
      source = Mutable.new([1]).freeze
      cloned = source.clone
      unfrozen = source.clone(freeze: false)
      duplicated = source.dup
      explicitly_frozen = Mutable.new([1]).clone(freeze: true)

      [cloned, explicitly_frozen].each do |copy|
        assert_predicate copy, :frozen?
        assert Ractor.shareable?(copy)
        assert_raises(FrozenError) { copy.push(2) }
      end
      [unfrozen, duplicated].each do |copy|
        refute_predicate copy, :frozen?
        assert Ractor.shareable?(copy)
        copy.push(2)

        assert_equal [1, 2], Mutable.deref(copy)
      end
      assert_equal [1], Mutable.deref(source)
      assert_predicate source, :frozen?
    end

    def test_factory_subclasses_forward_constructor_arguments
      klass = Mutable[Payload]
      mutable = klass.new(2, offset: 3) { it * 2 }

      assert_operator klass, :<, Mutable
      assert_same Payload, klass.value_factory
      assert_operator klass, :===, mutable
      assert_instance_of Payload, Mutable.deref(mutable)
      assert_equal 10, mutable.count
      refute_respond_to klass, :[]
      assert Ractor.shareable?(mutable)
    end

    def test_factory_is_inherited_by_further_subclasses
      klass = Class.new(Mutable[Array]) do
        def doubled = sum * 2
      end
      mutable = klass.new(2, 3)

      assert_same Array, klass.value_factory
      assert_equal [3, 3], Mutable.deref(mutable)
      assert_equal 12, mutable.doubled
      mutable.push(4)

      assert_equal 20, mutable.doubled
    end

    def test_rejects_an_unshareable_factory
      return unless Internal.native_ractors?
      factory = Object.new
      error = assert_raises(Ractor::IsolationError) { Mutable[factory] }

      assert_equal "factory is not shareable", error.message
      refute_predicate factory, :frozen?
    end

    def test_inspection_shows_the_current_snapshot
      mutable = Mutable.new([1, 2])
      snapshot = Mutable.deref(mutable)
      expected = "#<Farce::Mutable[Array] [1, 2]>"

      assert_equal expected, mutable.inspect
      assert_equal "#{expected}\n", PP.pp(mutable, +"", 200)
      assert_same snapshot, Mutable.deref(mutable)
      mutable.push(3)

      assert_equal "#<Farce::Mutable[Array] [1, 2, 3]>", mutable.inspect
      assert_equal "#<Farce::Mutable[Array] [nil, nil]>", Mutable[Array].new(2).inspect
    end

    def test_recursive_inspection_uses_an_identity_placeholder
      mutable = Mutable.new([])
      mutable.push(mutable)
      address = Kernel.instance_method(:to_s).bind_call(mutable)

      assert_includes mutable.inspect, address
      assert_includes PP.pp(mutable, +""), address
    end

    def test_explicitly_rejects_marshal_without_delegating_hooks_to_the_snapshot
      mutable = Mutable.new([1])
      snapshot = Mutable.deref(mutable)

      assert_respond_to mutable, :marshal_dump
      refute_respond_to mutable, :marshal_load
      refute_respond_to mutable, :_dump
      error = assert_raises(TypeError) { Marshal.dump(mutable) }

      assert_equal "Farce::Mutable cannot be marshaled", error.message
      assert_same snapshot, Mutable.deref(mutable)
      assert_same mutable, mutable.push(2)
    end

    def test_thread_updates_are_atomic
      mutable = Mutable.new([])
      ready = Thread::Queue.new
      start = Thread::Queue.new
      threads = 6.times.map do |index|
        Thread.new do
          ready.push(true)
          start.pop
          40.times { |offset| mutable.push((index * 40) + offset) }
        end
      end
      6.times { ready.pop }
      6.times { start.push(true) }
      threads.each(&:value)

      assert_equal (0...240).to_a, Mutable.deref(mutable).sort
      assert_predicate Mutable.deref(mutable), :frozen?
    end

    def test_ractor_updates_are_atomic_and_visible_to_the_creator
      mutable = Mutable.new([])
      snapshot = Mutable.deref(mutable)
      workers = 4.times.map do |index|
        Ractor.new(mutable, index) do |shared, worker_index|
          Ractor.receive
          20.times { |offset| shared.push((worker_index * 20) + offset) }
          Ractor.shareable?(Mutable.deref(shared))
        end
      end
      workers.each { it.send(:start) }
      # Release every worker before waiting for any result.
      # rubocop:disable-next Style/CombinableLoops
      workers.each { assert ractor_value(it) }

      assert_empty snapshot
      assert_equal (0...80).to_a, Mutable.deref(mutable).sort
    end

    def test_can_be_constructed_and_copied_in_a_non_main_ractor
      klass = Mutable[Array]
      worker = Ractor.new(klass) do |factory|
        source = factory.new(2, 1)
        copy = source.dup
        copy.push(2)
        [source, copy].freeze
      end
      source, copy = ractor_value(worker)

      assert_equal [1, 1], Mutable.deref(source)
      assert_equal [1, 1, 2], Mutable.deref(copy)
      source.push(3)

      assert_equal [1, 1, 3], Mutable.deref(source)
      assert_equal [1, 1, 2], Mutable.deref(copy)
    end
  end
end
