# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestDeduper < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakReferenceHelpers

    class Box
      attr_accessor :value

      def initialize(value) = @value = value
      def hash = value.hash
      def eql?(other) = other.is_a?(self.class) && value.eql?(other.value)
      alias == eql?
    end

    Record = Data.define(:children) do
      def initialize(children:)
        raise ArgumentError, "array expected" unless children.is_a?(Array)
        super
      end
    end

    def setup
      @deduper = Deduper.new
    end

    def test_facade_returns_the_default_deduper_without_arguments
      assert_instance_of Deduper, Farce.dedup
      assert_same Farce.dedup, Farce.dedup
      assert_nil Farce.dedup(nil)
    end

    def test_first_result_is_reused_while_retained
      first = @deduper.dedup([+"foo"])
      GC.start

      assert_same first, @deduper.dedup([+"foo"])
      assert_predicate first, :frozen?
      assert_same(-String.new("foo"), first.first)
    end

    def test_cache_does_not_keep_an_unreferenced_result_alive
      deduper = @deduper
      factory = Object.new
      factory.define_singleton_method(:new) do |value|
        reference = WeakRef.new(deduper.dedup([value]))
        deduper.dedup([:another_key])
        reference
      end
      reference = collected_reference(factory, freeze_value: true)

      refute_predicate reference, :weakref_alive?
    end

    def test_facade_forwards_copy_and_skip_options
      value = [+"facade"]
      result = Farce.dedup(value, copy: true)

      refute_same value, result
      refute_predicate value, :frozen?
      assert_predicate result, :frozen?
      assert_same value, Farce.dedup(value, skip: Array)
    end

    def test_facade_skip_configuration_in_a_fresh_process
      output, error, status = ruby_isolated(<<~RUBY)
        require "farce"
        Farce.dedup.skip(Array)
        input = [+"unchanged"]
        abort "copied skipped value" unless Farce.dedup(input, copy: true).equal?(input)
        abort "froze skipped value" if input.frozen? || input.first.frozen?
        puts "ok"
      RUBY

      assert_predicate status, :success?, error
      assert_equal "ok\n", output
    end

    def test_strings_and_immediate_values
      # JRuby's debug mode can give frozen literal expressions distinct identities.
      canonical = -String.new("text")

      assert_same canonical, @deduper.dedup(+"text")
      assert_same canonical, @deduper.dedup(String.new("text"))
      assert_nil @deduper.dedup(nil)
      [true, false, 42, :symbol, 1.5].each do |value|
        assert_same value, @deduper.dedup(value)
      end
    end

    def test_nested_arrays_hashes_and_sets_are_canonicalized
      left = { [+"key"] => ::Set[[+"value"]] }
      right = { [+"key"] => ::Set[[+"value"]] }
      first = @deduper.dedup(left)

      assert_same first, @deduper.dedup(right)
      assert_predicate first.keys.first, :frozen?
      assert_predicate first.values.first, :frozen?
      assert_predicate first.values.first.first, :frozen?
      assert_same @deduper.dedup([+"key"]), first.keys.first
    end

    def test_regular_expressions_are_canonicalized_by_default
      first = Farce.dedup(Regexp.new("dedup pattern", Regexp::IGNORECASE))
      GC.start

      assert_predicate first, :frozen?
      assert_same first, Farce.dedup(Regexp.new("dedup pattern", Regexp::IGNORECASE))
    end

    def test_data_records_are_canonicalized_by_default
      first = @deduper.dedup(Record.new(children: [+"value"]))
      GC.start

      assert_same first, @deduper.dedup(Record.new(children: [+"value"]))
      assert_predicate first.children, :frozen?
      assert_same @deduper.dedup([+"value"]), first.children
    end

    def test_ranges_are_canonicalized_by_default
      first = @deduper.dedup(1..3)
      GC.start

      assert_same first, @deduper.dedup(1..3)
      assert_predicate first, :frozen?
      refute_same first, @deduper.dedup(1...3)
      refute_same first, @deduper.dedup(1..4)
      [Range.new(nil, 3), Range.new(1, nil, true)].each do |range|
        canonical = @deduper.dedup(range)

        assert_same canonical, @deduper.dedup(Range.new(range.begin, range.end, range.exclude_end?))
      end
    end

    def test_range_copy_deduplicates_endpoints_without_freezing_inputs
      input = Range.new([1], [3], true)
      result = @deduper.dedup(input, copy: true)

      refute_same input, result
      assert_same result, @deduper.dedup(Range.new([1], [3], true), copy: true)
      assert_same @deduper.dedup([1]), result.begin
      assert_same @deduper.dedup([3]), result.end
      assert_predicate result, :exclude_end?
      refute_predicate input.begin, :frozen?
      refute_predicate input.end, :frozen?
      assert_predicate result.begin, :frozen?
      assert_predicate result.end, :frozen?
    end

    def test_nested_ranges_are_canonicalized
      result = @deduper.dedup([Range.new(1, 3), Range.new(1, 3)])

      assert_same result.first, result.last
    end

    def test_cyclic_ranges_are_not_cached
      children = []
      input = Range.new(children, children)
      children << input
      first = @deduper.dedup(input, copy: true)
      second = @deduper.dedup(input, copy: true)

      refute_same first, second
      assert_same first, first.begin.first
      assert_same second, second.begin.first
      assert_same input, children.first
      refute_predicate children, :frozen?
    end

    def test_data_copy_preserves_input_members
      input = Record.new(children: [+"value"])
      first = @deduper.dedup(input, copy: true)

      refute_same input, first
      refute_predicate input.children, :frozen?
      refute_predicate input.children.first, :frozen?
      assert_predicate first.children, :frozen?
      assert_same first, @deduper.dedup(Record.new(children: [+"value"]), copy: true)
    end

    def test_data_records_with_different_classes_or_members_remain_distinct
      other_class = Data.define(:children)
      first = @deduper.dedup(Record.new(children: [1]))

      refute_same first, @deduper.dedup(Record.new(children: [2]))
      refute_same first, @deduper.dedup(other_class.new(children: [1]))
    end

    def test_nested_regular_expressions_are_canonicalized
      result = @deduper.dedup([Regexp.new("pattern"), Regexp.new("pattern")])

      assert_same result.first, result.last
      assert_predicate result.first, :frozen?
    end

    def test_regular_expression_patterns_and_options_remain_distinct
      first = @deduper.dedup(Regexp.new("pattern"))
      other_pattern = @deduper.dedup(Regexp.new("other"))
      other_options = @deduper.dedup(Regexp.new("pattern", Regexp::IGNORECASE))

      refute_same first, other_pattern
      refute_same first, other_options
      assert_equal(/other/, other_pattern)
      assert_equal(/pattern/i, other_options)
    end

    def test_copy_preserves_regular_expression_inputs
      input = Regexp.new("pattern")
      frozen = input.frozen?
      result = @deduper.dedup(input, copy: true)

      # TruffleRuby freezes regular expressions when they are created.
      frozen ? assert_same(input, result) : refute_same(input, result)

      assert_equal frozen, input.frozen?
      assert_predicate result, :frozen?
      assert_same result, @deduper.dedup(Regexp.new("pattern"), copy: true)
    end

    def test_copy_preserves_all_mutable_input_containers
      key = [+"key"]
      child = [+"value"]
      input = { key => [child, child] }
      result = @deduper.dedup(input, copy: true)

      refute_same input, result
      refute_same key, result.keys.first
      refute_same child, result.values.first.first
      assert_same result.values.first.first, result.values.first.last
      [input, key, input[key], child, child.first].each { refute_predicate it, :frozen? }
    end

    def test_unchanged_frozen_containers_are_not_copied
      leaf = Object.new.freeze
      child = [leaf].freeze
      root = [child].freeze

      assert_same root, @deduper.dedup(root, copy: true)
      assert_same child, root.first
      assert_same leaf, child.first
    end

    def test_empty_containers_are_copied_before_freezing
      [[], {}, ::Set.new].each do |value|
        result = @deduper.dedup(value, copy: true)

        refute_same value, result
        refute_predicate value, :frozen?
        assert_predicate result, :frozen?
      end
    end

    def test_skip_excludes_an_entire_subtree
      value = Box.new([+"skip"])

      assert_same @deduper, @deduper.skip(Box)
      assert_same value, @deduper.dedup(value, copy: true)
      refute_predicate value.value, :frozen?
      refute_predicate value.value.first, :frozen?
    end

    def test_per_call_skip_does_not_change_configuration
      value = [+"skip"]

      assert_same value, @deduper.dedup(value, skip: [Array])
      refute_predicate value, :frozen?
      assert_predicate @deduper.dedup(value), :frozen?
    end

    def test_modules_are_skipped_by_default
      klass = Class.new
      child = [+"unchanged"]
      klass.instance_variable_set(:@child, child)

      assert_same klass, @deduper.dedup(klass)
      refute_predicate child, :frozen?
    end

    def test_unconfigured_objects_are_traversed_but_not_interned
      first = Box.new([+"value"])
      second = Box.new([+"value"])

      assert_same first, @deduper.dedup(first)
      assert_same second, @deduper.dedup(second)
      assert_same first.value, second.value
      refute_predicate first, :frozen?
    end

    def test_store_adds_custom_value_classes
      assert_same @deduper, @deduper.store(Box)
      first = @deduper.dedup(Box.new([+"value"]))

      assert_predicate first, :frozen?
      assert_same first, @deduper.dedup(Box.new([+"value"]))
    end

    def test_separate_dedupers_have_separate_container_caches
      first = @deduper.dedup([+"separate"])
      second = Deduper.new.dedup([+"separate"])

      refute_same first, second
      assert_same first.first, second.first
    end

    def test_copied_cycles_point_to_the_copy
      input = []
      input << input
      result = @deduper.dedup(input, copy: true)

      refute_same input, result
      assert_same result, result.first
      assert_same input, input.first
      refute_predicate input, :frozen?
      assert_predicate result, :frozen?
    end

    def test_copied_mutual_cycles_do_not_reach_the_source
      input = {}
      input[:child] = [input]
      result = @deduper.dedup(input, copy: true)

      assert_same result, result[:child].first
      refute_same input, result
      refute_same input[:child], result[:child]
      refute_predicate input, :frozen?
      refute_predicate input[:child], :frozen?
    end

    def test_copied_data_cycles_use_the_frozen_replacement
      children = []
      original = Record.new(children:)
      children << original
      result = @deduper.dedup(original, copy: true)

      assert_same result, result.children.first
      assert_same original, children.first
      refute_same children, result.children
      refute_predicate children, :frozen?
      assert_predicate result, :frozen?
      assert_predicate result.children, :frozen?
    end

    def test_repeated_data_cycles_preserve_each_replacements_back_reference
      children = []
      original = Record.new(children:)
      children << original
      first = @deduper.dedup(original, copy: true)
      second = @deduper.dedup(original, copy: true)

      assert_same first, first.children.first
      assert_same second, second.children.first
      refute_same first, second
      assert_same original, original.children.first
    end

    def test_simultaneous_calls_reuse_a_retained_result
      ready = Thread::Queue.new
      start = Thread::Queue.new
      threads = Array.new(8) do
        Thread.new do
          ready << true
          start.pop
          @deduper.dedup([+"concurrent"])
        end
      end
      threads.size.times { ready.pop }
      threads.size.times { start << true }
      results = threads.map(&:value)

      results.each { assert_same results.first, it }
    ensure
      threads&.each { it.kill if it.alive? }
      threads&.each(&:join)
    end

    def test_shareable_canonical_objects_are_reused_across_ractors
      first = @deduper.dedup([+"shared"])
      worker = Ractor.new(@deduper, first) do |deduper, canonical|
        deduper.dedup([+"shared"]).equal?(canonical)
      end

      assert ractor_value(worker)
    end
  end
end
