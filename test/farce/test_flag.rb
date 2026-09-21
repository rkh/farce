# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "internal/test_flag"

module Farce
  class TestFlag < Internal::TestFlag
    def test_public_type_and_shareability
      flag = Flag.new

      assert_equal Internal::Flag, Flag.superclass
      assert_kind_of Abstract::Flag, flag
      assert_kind_of Abstract::Value, flag
      refute_predicate flag, :frozen?
      assert_predicate flag, :ractor_shareable?
      assert Ractor.shareable?(flag)
      refute flag.unwrap
      flag.set

      assert flag.unwrap
    end

    def test_only_one_thread_claims_the_flag
      flag = Flag.new
      workers = 8.times.map { Thread.new { flag.compare_and_set(false, true) } }

      assert_equal 1, workers.count(&:value)
      assert flag.value
    end

    def test_copies_have_independent_state_and_ruby_frozen_semantics
      flag = Flag.new(false)
      flag.freeze

      duplicated = flag.dup
      cloned = flag.clone
      unfrozen_clone = flag.clone(freeze: false)

      refute_predicate duplicated, :frozen?
      assert_predicate cloned, :frozen?
      refute_predicate unfrozen_clone, :frozen?
      [duplicated, cloned, unfrozen_clone].each { assert Ractor.shareable?(it) }

      duplicated.set
      unfrozen_clone.set

      refute flag.value
      assert duplicated.value
      refute cloned.value
      assert unfrozen_clone.value
    end

    def test_construction_inside_a_non_main_ractor_publishes_the_flag
      return unless Internal.native_ractors?

      worker = Ractor.new do
        flag = Farce::Flag.new(true)
        [flag.frozen?, Ractor.shareable?(flag), flag.value].freeze
      end

      assert_equal [false, true, true], ractor_value(worker)
    end

    def test_stateful_native_subclass_is_rejected_during_publication
      return unless Internal.native_ractors?

      subclass = Class.new(Flag) do
        def initialize
          @ruby_state = true
          super
        end
      end

      error = assert_raises(TypeError) { subclass.new }

      assert_match(/cannot be published with Ruby instance variables/, error.message)
    end

    private def flag_class = Farce::Flag
  end
end
