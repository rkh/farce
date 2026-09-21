# frozen_string_literal: true

require_relative "../setup"
require "pp"

module Farce
  class TestLazy < Test
    include Helpers::InternalTestHelpers

    class CountingFactory
      def initialize(calls, result)
        @calls = calls
        @result = result
      end

      def call
        @calls.increment
        Thread.pass
        @result
      end
    end

    class FlakyFactory
      def initialize(calls)
        @calls = calls
      end

      def call
        @calls.increment
        raise "not yet" if @calls.value == 1

        :ready
      end
    end

    class UnshareableThenValueFactory
      def initialize(calls)
        @calls = calls
      end

      def call
        @calls.increment
        @calls.value == 1 ? Object.new : :ready
      end
    end

    class ClassFactory
      def self.new = :created
    end

    def test_is_an_abstract_value_and_is_shareable
      lazy = Lazy.new { 42 }

      assert_kind_of Abstract::Value, lazy
      refute_predicate lazy, :frozen?
      assert_predicate lazy, :ractor_shareable?
      assert Ractor.shareable?(lazy) if Internal.native_ractors?

      assert_equal 42, lazy.unwrap
    end

    def test_computes_a_callable_factory_only_once
      calls = Counter.new
      result = "result"
      lazy = Lazy.new(CountingFactory.new(calls, result))

      assert_equal 0, calls.value
      assert_same result, lazy.value
      assert_same result, lazy.value
      assert_equal 1, calls.value
    end

    def test_caches_nil
      calls = Counter.new
      lazy = Lazy.new(CountingFactory.new(calls, nil))

      assert_nil lazy.value
      assert_nil lazy.value
      assert_equal 1, calls.value
    end

    def test_caches_false
      calls = Counter.new
      lazy = Lazy.new(CountingFactory.new(calls, false))

      refute lazy.value
      refute lazy.value
      assert_equal 1, calls.value
      assert_equal "#<Farce::Lazy false>", lazy.inspect
      assert_equal "#<Farce::Lazy false>", lazy.pretty_inspect.chomp
    end

    def test_accepts_a_proc_factory
      lazy = Lazy.new(-> { 42 })

      assert_equal 42, lazy.value
    end

    def test_binds_a_block_to_the_self_option
      lazy = Lazy.new(self: 40) { self + 2 }

      assert_equal 42, lazy.value
    end

    def test_uses_new_for_a_class_factory
      lazy = Lazy.new(ClassFactory)

      assert_equal :created, lazy.value
    end

    def test_rejects_a_factory_and_block_together
      error = assert_raises(ArgumentError) { Lazy.new(ClassFactory) { :block } }

      assert_equal "factory and block cannot be both given", error.message
    end

    def test_retries_after_the_factory_raises
      calls = Counter.new
      lazy = Lazy.new(FlakyFactory.new(calls))

      assert_raises(RuntimeError) { lazy.value }
      assert_equal :ready, lazy.value
      assert_equal :ready, lazy.value
      assert_equal 2, calls.value
    end

    def test_freeze_retries_after_factory_failure
      calls = Counter.new
      lazy = Lazy.new(FlakyFactory.new(calls))

      assert_raises(RuntimeError) { lazy.freeze }
      refute_predicate lazy, :frozen?
      assert_same lazy, lazy.freeze
      assert_predicate lazy, :frozen?
      assert_equal :ready, lazy.value
      assert_equal 2, calls.value
    end

    def test_freeze_caches_nil_without_freezing_the_factory_result
      calls = Counter.new
      lazy = Lazy.new(CountingFactory.new(calls, nil))

      assert_same lazy, lazy.freeze
      assert_nil lazy.value
      assert_nil lazy.value
      assert_equal 1, calls.value
    end

    def test_copies_share_evaluation_and_keep_independent_logical_freeze_state
      calls = Counter.new
      result = Map.new
      source = Lazy.new(CountingFactory.new(calls, result))
      frozen_copy = source.dup

      assert_same frozen_copy, frozen_copy.freeze

      duplicated = frozen_copy.dup
      cloned = frozen_copy.clone
      mutable_clone = frozen_copy.clone(freeze: false)
      lazies = [source, frozen_copy, duplicated, cloned, mutable_clone]
      slots = lazies.map { it.instance_variable_get(:@atom) }

      assert_equal 1, slots.map(&:object_id).uniq.length
      refute_predicate source, :frozen?
      assert_predicate frozen_copy, :frozen?
      refute_predicate duplicated, :frozen?
      assert_predicate cloned, :frozen?
      refute_predicate mutable_clone, :frozen?
      lazies.each { assert_same result, it.value }

      assert_equal 1, calls.value
      refute_predicate result, :frozen?
    end

    def test_computes_once_under_thread_contention
      calls = Counter.new
      lazy = Lazy.new(CountingFactory.new(calls, 42))
      workers = 8.times.map { Thread.new { lazy.value } }

      assert_equal [42], workers.map(&:value).uniq
      assert_equal 1, calls.value
    ensure
      workers&.each { it.kill.join }
    end

    def test_computes_once_across_ractors
      return unless Internal.native_ractors?

      calls = Counter.new
      lazy = Lazy.new(CountingFactory.new(calls, 42))
      workers = 4.times.map { Ractor.new(lazy, &:value) }

      assert_equal [42], workers.map { |worker| ractor_value(worker) }.uniq
      assert_equal 1, calls.value
    end

    def test_rejects_an_unshareable_result_and_can_retry
      return unless Internal.native_ractors?

      calls = Counter.new
      lazy = Lazy.new(UnshareableThenValueFactory.new(calls))

      assert_raises(Ractor::IsolationError) { lazy.value }
      assert_equal :ready, lazy.value
      assert_equal 2, calls.value
    end

    def test_delegates_missing_methods_to_the_value
      lazy = Lazy.new { "value" }

      assert_respond_to lazy, :upcase
      assert_equal "VALUE", lazy.upcase
      refute_respond_to lazy, :not_a_string_method
      assert_raises(NoMethodError) { lazy.not_a_string_method }
    end

    def test_inspect_and_pretty_print_do_not_compute_the_value
      lazy = Lazy.new(ClassFactory)

      assert_equal "#<Farce::Lazy #{ClassFactory}>", lazy.inspect
      assert_equal "#<Farce::Lazy #{ClassFactory}>", lazy.pretty_inspect.chomp
      assert_equal :created, lazy.value
      assert_equal "#<Farce::Lazy :created>", lazy.inspect
      assert_equal "#<Farce::Lazy :created>", lazy.pretty_inspect.chomp
    end
  end
end
