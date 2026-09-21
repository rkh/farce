# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "internal/test_flag"

module Farce
  class TestLocalFlag < Internal::TestFlag
    def test_public_type_and_scope_validation
      flag = flag_class.new

      assert_kind_of Abstract::Flag, flag
      assert_kind_of Abstract::Value, flag
      assert_equal :ractor, flag.scope
      refute_predicate flag, :frozen?
      assert_predicate flag, :ractor_shareable?
      assert_raises(ArgumentError) { flag_class.new(scope: :global) }
      assert_raises(FrozenError) { flag.send(:initialize, true) }
      refute flag.unwrap
      flag.set

      assert flag.unwrap
    end

    def test_frozen_uninitialized_flag_cannot_be_initialized
      flag = flag_class.allocate.freeze

      assert_raises(FrozenError) { flag.send(:initialize, true) }
    end

    def test_flag_sent_to_a_ractor_is_the_same_object
      flag = flag_class.new
      worker = Ractor.new(flag) do |local|
        local.set
        [local.object_id, local.value]
      end

      assert_equal [flag.object_id, true], ractor_value(worker)
      refute flag.value
    end

    def test_ractor_starts_with_initial_value
      flag = flag_class.new(true)
      flag.store(false)
      worker = Ractor.new(flag) { |local| [local.value, local.toggle] }

      assert_equal [true, false], ractor_value(worker)
      refute flag.value
    end

    def test_thread_and_fiber_isolation
      %i[thread fiber].each do |scope|
        flag = flag_class.new(true, scope:)
        flag.store(false)
        work = proc { [flag.value, flag.toggle] }
        result = scope == :thread ? Thread.new(&work).value : Fiber.new(&work).resume

        assert_equal [true, false], result
        refute flag.value
      end
    end

    def test_thread_group_isolation
      flag = flag_class.new(scope: :thread_group)
      flag.set
      group = ThreadGroup.new
      result = Thread.new do
        inherited = flag.value
        group.add(Thread.current)
        initial = flag.value
        Thread.new { flag.set }.join
        [inherited, initial, flag.value]
      end.value

      assert_equal [true, false, true], result
      assert flag.value
    end

    def test_fiber_storage_inheritance
      flag = flag_class.new(scope: :fiber_storage)
      flag.set

      assert Fiber.new { flag.value }.resume
      refute Fiber.new(storage: {}) { flag.value }.resume
      refute Fiber.new { flag.toggle }.resume
      refute flag.value
    end

    private def flag_class = Local::Flag
  end
end
