# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLocal < Test
    include Helpers::InternalTestHelpers

    def test_is_a_shareable_value_with_ractor_scope_by_default
      local = Local.new

      assert_kind_of Abstract::Value, local
      assert_equal :ractor, local.scope
      assert_predicate local, :frozen?
      assert_predicate local, :ractor_shareable?
      assert Ractor.shareable?(local)
      assert_nil local.value
      assert_nil local.unwrap
    end

    def test_reads_defaults_and_preserves_assigned_values
      local = Local.new(:default)
      value = []

      assert_equal :default, local.value
      local.value = value

      assert_same value, local.value
      local.value = nil

      assert_nil local.value
      local.value = false

      refute local.value
    end

    def test_unwraps_nested_values
      local = Local.new
      local.value = Local.new(42)

      assert_equal 42, local.unwrap
    end

    def test_reading_the_default_does_not_store_a_value
      local = Local.new(:default)

      assert_equal :default, local.value
      assert_equal(:stored, local.store_if_absent { :stored })
      assert_equal :stored, local.value
    end

    def test_mutable_defaults_are_shared_by_fibers_in_the_same_ractor
      local = Local.new([], scope: :fiber)
      value = local.value
      value << :parent

      assert_same value, Fiber.new { local.value }.resume
      assert_equal [:parent], local.value
    end

    def test_rejects_invalid_scopes
      [:global, :invalid, "thread", nil, Thread].each do |scope|
        assert_raises(ArgumentError) { Local.new(scope:) }
      end
    end

    def test_initializer_is_lazy_and_caches_its_result
      calls = Counter.new
      local = Local.new(:default) do
        calls.increment
        []
      end

      assert_equal 0, calls.value
      value = local.value
      value << :changed

      assert_same value, local.value
      assert_equal [:changed], local.value
      assert_equal 1, calls.value
    end

    def test_assignment_skips_initializer_even_for_nil_and_false
      local = Local.new { raise "initializer should not run" }

      local.value = nil

      assert_nil local.value
      local.value = false

      refute local.value
    end

    def test_initializer_caches_nil_and_false
      [nil, false].each do |result|
        calls = Counter.new
        local = Local.new do
          calls.increment
          result
        end

        2.times { result.nil? ? assert_nil(local.value) : assert_instance_of(FalseClass, local.value) }

        assert_equal 1, calls.value
      end
    end

    def test_initializer_retries_after_an_exception
      calls = Counter.new
      local = Local.new do
        raise "not ready" if calls.increment == 1
        :ready
      end

      assert_raises(RuntimeError) { local.value }
      assert_equal :ready, local.value
      assert_equal :ready, local.value
      assert_equal 2, calls.value
    end

    def test_store_if_absent_overrides_an_unread_default_or_initializer
      [Local.new(:default), Local.new { raise "initializer should not run" }].each do |local|
        value = []

        assert_same(value, local.store_if_absent { value })
        assert_same value, local.value
        assert_same(value, local.store_if_absent { flunk "value already stored" })
      end
    end

    def test_store_if_absent_preserves_nil_and_false
      local = Local.new(:default)

      assert_nil(local.store_if_absent { nil })
      assert_nil(local.store_if_absent { flunk "value already stored" })
      assert_nil local.value

      local = Local.new(:default)

      assert_instance_of(FalseClass, local.store_if_absent { false })
      assert_instance_of(FalseClass, local.store_if_absent { flunk "value already stored" })
      assert_instance_of FalseClass, local.value
    end

    def test_store_if_absent_retries_after_an_exception
      local = Local.new

      assert_raises(RuntimeError) { local.store_if_absent { raise "not ready" } }
      assert_equal(:ready, local.store_if_absent { :ready })
    end

    def test_store_if_absent_requires_a_block_even_when_set
      local = Local.new

      assert_raises(LocalJumpError) { local.store_if_absent }
      local.value = :set
      assert_raises(LocalJumpError) { local.store_if_absent }
    end

    def test_instances_have_independent_values
      first = Local.new { [] }
      second = Local.new { [] }
      first.value << :first

      assert_empty second.value
      second.value = :second

      assert_equal [:first], first.value
    end

    def test_fiber_scope_is_isolated
      local = Local.new(:default, scope: :fiber)
      local.value = :parent

      result = Fiber.new do
        before = local.value
        local.value = :child
        [before, local.value]
      end.resume

      assert_equal %i[default child], result
      assert_equal :parent, local.value
    end

    def test_thread_scope_is_shared_by_fibers_but_isolated_between_threads
      local = Local.new(:default, scope: :thread)
      local.value = :parent

      assert_equal :parent, Fiber.new { local.value }.resume
      worker = Thread.new do
        before = local.value
        local.value = :child
        [before, Fiber.new { local.value }.resume]
      end

      assert_equal %i[default child], worker.value
      assert_equal :parent, local.value
    ensure
      worker&.kill&.join
    end

    def test_thread_group_scope_is_shared_within_a_group
      local = Local.new(:default, scope: :thread_group)
      local.value = :parent
      group = ThreadGroup.new
      worker = Thread.new do
        before = local.value
        group.add(Thread.current)
        isolated = local.value
        local.value = :group
        [before, isolated, Thread.new { local.value }.value]
      end

      assert_equal %i[parent default group], worker.value
      assert_equal :parent, local.value
    ensure
      worker&.kill&.join
    end

    def test_fiber_storage_scope_follows_inherited_storage
      local = Local.new(:default, scope: :fiber_storage)
      local.value = :parent

      assert_equal :parent, Fiber.new { local.value }.resume
      result = Fiber.new(storage: {}) do
        before = local.value
        local.value = :child
        [before, Fiber.new { local.value }.resume]
      end.resume

      assert_equal %i[default child], result
      assert_equal :parent, local.value
    end

    def test_ractor_scope_is_shared_by_threads
      local = Local.new(:default)
      local.value = :parent
      worker = Thread.new do
        before = local.value
        local.value = :child
        before
      end

      assert_equal :parent, worker.value
      assert_equal :child, local.value
    ensure
      worker&.kill&.join
    end

    def test_initializes_once_under_thread_contention
      calls = Counter.new
      local = Local.new do
        calls.increment
        Thread.pass
        []
      end
      workers = 8.times.map { Thread.new { local.value } }
      values = workers.map(&:value)

      values.each { assert_same values.first, it }

      assert_equal 1, calls.value
    ensure
      workers&.each { it.kill.join }
    end

    def test_initializer_runs_independently_in_each_fiber
      local = Local.new(scope: :fiber) { [] }
      local.value << :parent
      result = Fiber.new do
        before = local.value.dup
        local.value << :child
        [before, local.value]
      end.resume

      assert_equal [[], [:child]], result
      assert_equal [:parent], local.value
    end

    def test_ractor_scope_is_isolated
      local = Local.new(:default)
      local.value = :parent
      worker = Ractor.new(local) do |shared|
        before = shared.value
        shared.value = :child
        [before, shared.value]
      end

      assert_equal %i[default child], ractor_value(worker)
      assert_equal :parent, local.value
    end

    def test_initializer_can_return_mutable_values_in_each_ractor
      local = Local.new { [] }
      local.value << :parent
      worker = Ractor.new(local) do |shared|
        before = shared.value.dup
        shared.value << :child
        [before, shared.value]
      end

      assert_equal [[], [:child]], ractor_value(worker)
      assert_equal [:parent], local.value
    end
  end
end
