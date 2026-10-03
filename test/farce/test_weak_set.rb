# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "psych"

module Farce
  class TestWeakSet < Test
    include Helpers::InternalTestHelpers

    def test_default_mode_and_unsupported_modes
      set = WeakSet[:existing]

      assert_equal :raise, set.mode
      assert_predicate set, :weak?
      assert Ractor.shareable?(set)
      [:copy, :move, :local, :shareable_copy, :proxy, :invalid, false, 1].each do |mode|
        assert_raises(ArgumentError) { WeakSet.new(mode:) }
        assert_raises(ArgumentError) { WeakSet.new([nil], mode:) }
        assert_raises(ArgumentError) { set.add(nil, mode:) }
        assert_raises(ArgumentError) { set.add?(:existing, mode:) }
        assert_equal [:existing], set.to_a
      end
    end

    def test_raise_rejects_unshareable_elements_without_changing_membership
      set = WeakSet[:existing]
      value = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) { WeakSet.new([value]) }
      assert_raises(Ractor::IsolationError) { set.add(value) }
      assert_raises(Ractor::IsolationError) { set.add?(value) }
      assert_equal [:existing], set.to_a
      assert_same set, set.add(:recovered)
    end

    def test_make_shareable_preserves_element_identity_and_set_return_values
      element = [Object.new]
      set = WeakSet.new([element], mode: :make_shareable)

      assert_equal :make_shareable, set.mode
      assert_same element, set.first
      assert Ractor.shareable?(element)
      assert_same set, set.add(element)
      assert_nil set.add?(element)
      second = [2]

      assert_same set, set.add?(second)
      assert_includes set, second
      assert_same(second, set.find { it.equal?(second) })
    end

    def test_insertions_accept_per_operation_modes_without_changing_default
      set = WeakSet.new
      element = [1]

      assert_same set, set.add(element, mode: :make_shareable)
      assert_equal :raise, set.mode
      assert_same element, set.first
      duplicate = [1]

      assert_nil set.add?(duplicate, mode: :make_shareable)
      assert_equal 1, set.size
      assert_same set, set.add(:symbol, mode: nil)
      assert_same set, set << :another
    end

    def test_structural_lookup_and_deletion_do_not_prepare_their_arguments
      element = [1].freeze
      set = WeakSet.new([element], mode: :make_shareable)
      query = [1]

      assert_includes set, query
      assert_operator set, :member?, query
      assert_operator set, :===, query
      assert_same set, set.delete?(query)
      assert_empty set
      refute_predicate query, :frozen?
      set.add(element)

      assert_same set, set.subtract([query])
      assert_empty set
      refute_predicate query, :frozen?
      set.add(element)

      assert_same set, set.delete(query)
      assert_nil set.delete?(query)
      refute_predicate query, :frozen?
    end

    def test_identity_membership_uses_the_prepared_element
      element = [1]
      query = [1]
      set = WeakSet.new([element], mode: :make_shareable, compare_by_identity: true)

      assert_same element, set.first
      assert_includes set, element
      refute_includes set, query
      assert_nil set.delete?(query)
      assert_same set, set.delete(query)
      refute_predicate query, :frozen?
      assert_same set, set.delete?(element)
      assert_empty set
    end

    def test_dedup_reuses_a_canonical_element_retained_elsewhere
      return unless Internal.native_ractors?

      canonical = Ractor.make_shareable(Farce.dedup([String.new("weak set canonical")]))
      input = [String.new("weak set canonical")]
      set = WeakSet.new(mode: :dedup, compare_by_identity: true)

      assert_same set, set.add(input)
      assert_same canonical, set.first
      refute_includes set, input
      refute_predicate input, :frozen?
      3.times { GC.start }

      assert_includes set, canonical
      assert_same canonical, set.first
      assert_nil set.add?([String.new("weak set canonical")])
    end

    def test_shareable_elements_pass_through_without_deduplicating_again
      first = [String.new("weak set pass through")]
      second = [String.new("weak set pass through")]
      Ractor.make_shareable(first)
      Ractor.make_shareable(second)
      set = WeakSet.new([first, second], mode: :dedup, compare_by_identity: true)

      assert_equal 2, set.size
      assert_includes set, first
      assert_includes set, second
    end

    def test_dedup_input_does_not_keep_the_canonical_element_alive
      return unless Internal.native_ractors?

      holder = []
      set = Thread.new do
        canonical = Ractor.make_shareable(Farce.dedup([String.new("weak set collected canonical")]))
        input = [String.new("weak set collected canonical")]
        holder << input
        result = WeakSet.new([canonical], mode: :dedup)
        result.add(input)
        result
      end.value

      assert_collected(set)
      assert_equal [["weak set collected canonical"]], holder
    end

    def test_live_and_frozen_sets_do_not_retain_prepared_elements
      %i[raise make_shareable dedup].each do |mode|
        [false, true].each do |freeze_set|
          set = Thread.new do
            element = [Object.new]
            Ractor.make_shareable(element) if mode == :raise
            result = WeakSet.new([element], mode:)
            result.freeze if freeze_set
            result
          end.value

          assert_collected(set)
        end
      end
    end

    def test_copies_and_derived_sets_preserve_modes_and_stored_elements
      element = [1].freeze
      source = WeakSet.new([element], mode: :dedup, compare_by_identity: true)
      copy = source.dup
      results = [source.dup, source.clone, source | copy, source & copy,
                 source.select { true }, source.classify { :group }.fetch(:group)]
      results.each do |result|
        assert_instance_of WeakSet, result
        assert_equal :dedup, result.mode
        assert_predicate result, :compare_by_identity?
        assert_same element, result.first
      end
      results.first.clear

      assert_same element, source.first
      source.freeze

      assert_predicate source.clone, :frozen?
      refute_predicate source.dup, :frozen?
      assert_same element, source.clone(freeze: false).first
    end

    def test_normalization_precedes_preparation_and_is_not_repeated_by_algebra
      normalize = Ractor.shareable_proc { |value| value + 1 }
      set = WeakSet.new([1, 2], normalize:, mode: :make_shareable) { it * 2 }

      assert_equal [3, 5], set.to_a.sort
      assert_same set, set.add(5)
      assert_equal [3, 5, 6], set.to_a.sort
      copy = set.dup

      assert_equal [3, 5, 6], (set | copy).to_a.sort
      assert_equal [3, 5, 6], (set & copy).to_a.sort
      assert_empty set - copy
      assert_empty set ^ copy
    end

    def test_merge_prepares_canonical_elements_from_other_variants
      element = [1]
      source = Unshared::WeakSet.new([element])
      set = WeakSet.new(mode: :make_shareable)

      assert_same set, set.merge(source)
      assert_same element, set.first
      assert Ractor.shareable?(element)
      rejected = Unshared::Queue.new
      unshared = Unshared::Set[rejected]
      strict = WeakSet.new

      assert_raises(Ractor::IsolationError) { strict.merge(unshared) }
      assert_empty strict
    end

    def test_frozen_sets_reject_writes_without_preparing_the_input
      set = WeakSet[:existing]
      set.freeze
      element = []

      assert_raises(FrozenError) { set.add(element, mode: :make_shareable) }
      assert_raises(FrozenError) { set.add?(element, mode: :make_shareable) }
      assert_raises(FrozenError) { set.merge([element]) }
      assert_raises(FrozenError) { set.delete(:missing) }
      assert_raises(FrozenError) { set.delete?(:missing) }
      assert_raises(FrozenError) { set.clear }
      refute_predicate element, :frozen?
      assert_equal [:existing], set.to_a
    end

    def test_conditional_insertion_and_deletion_remain_atomic
      set = WeakSet.new(mode: :make_shareable)
      elements = Array.new(8) { [1] }
      ready = Thread::Queue.new
      start = Thread::Queue.new
      workers = elements.map do |element|
        Thread.new do
          ready << true
          start.pop
          set.add?(element)
        end
      end
      8.times { ready.pop }
      8.times { start << true }

      assert_equal(1, workers.count { it.value.equal?(set) })
      assert_equal 1, set.size
      workers = Array.new(8) { Thread.new { set.delete?([1]) } }

      assert_equal(1, workers.count { it.value.equal?(set) })
      assert_empty set
    end

    def test_yaml_preserves_mode_identity_and_normalization
      %i[raise make_shareable dedup].each do |mode|
        normalize = :succ
        source = WeakSet.new([1, 2], mode:, normalize:, compare_by_identity: true)
        source.freeze
        restored = Psych.unsafe_load(Psych.dump(source))

        assert_equal mode, restored.mode
        assert_predicate restored, :compare_by_identity?
        assert_predicate restored, :frozen?
        assert_equal [2, 3], restored.to_a.sort
        assert_includes restored, 1
        assert_includes restored, 2
      end
    end

    def test_other_ractors_can_prepare_elements_and_observe_the_same_object
      return unless Internal.native_ractors?

      set = WeakSet.new(mode: :make_shareable)
      worker = Ractor.new(set) do |shared|
        element = [Ractor.current.__id__]
        shared.add(element)
        [element, shared.first.equal?(element)]
      end
      element, identical = ractor_value(worker)

      assert identical
      assert_same element, set.first
      assert_includes set, element
    end

    def test_transactions_still_reject_weak_sets
      set = WeakSet[:original]

      assert_raises(TypeError) { Farce.transaction { |transaction| transaction[set].add(:replacement) } }
      assert_equal [:original], set.to_a
    end

    private

    def assert_collected(set)
      50.times do
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        return assert_empty(set) if set.empty?
        sleep 0.01
      end

      flunk "weak set retained its element after repeated collections"
    end
  end
end
