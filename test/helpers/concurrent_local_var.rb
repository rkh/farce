# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  module ConcurrentLocalVar
    def test_default_value_and_assignment
      variable = local_var_class.new(:default)

      assert_equal :default, variable.value
      assert_equal :changed, variable.value = :changed
      assert_equal :changed, variable.value
      assert_nil local_var_class.new.value
    end

    def test_variables_have_independent_values
      first = local_var_class.new(:first)
      second = local_var_class.new(:second)
      first.value = :changed

      assert_equal :changed, first.value
      assert_equal :second, second.value
    end

    def test_explicit_nil_and_false_do_not_restore_the_default
      variable = local_var_class.new(:default)
      variable.value = nil

      assert_nil variable.value
      variable.value = false

      refute variable.value
    end

    def test_default_block_is_lazy_and_cached
      calls = 0
      variable = local_var_class.new { calls += 1 }

      assert_equal 0, calls
      assert_equal 1, variable.value
      assert_equal 1, variable.value
      assert_equal 1, calls
    end

    def test_nil_and_false_default_results_are_cached
      calls = 0
      variable = local_var_class.new do
        calls += 1
        nil
      end

      2.times { assert_nil variable.value }

      assert_equal 1, calls
      variable = local_var_class.new do
        calls += 1
        false
      end

      2.times { refute variable.value }

      assert_equal 2, calls
    end

    def test_failed_default_block_can_be_retried
      calls = 0
      variable = local_var_class.new do
        raise "default failed" if (calls += 1) == 1
        :default
      end

      assert_raises(RuntimeError) { variable.value }
      assert_equal :default, variable.value
      assert_equal 2, calls
    end

    def test_nested_bindings_restore_values_and_return_the_block_result
      variable = local_var_class.new(:default)
      result = variable.bind(:outer) do
        assert_equal :outer, variable.value
        inner_result = variable.bind(:inner) { variable.value }

        assert_equal :inner, inner_result
        assert_equal :outer, variable.value
        :result
      end

      assert_equal :result, result
      assert_equal :default, variable.value
    end

    def test_binding_before_first_read_preserves_the_default
      calls = 0
      variable = local_var_class.new { calls += 1 }

      assert_equal :temporary, variable.bind(:temporary) { variable.value }
      assert_equal 1, variable.value
      assert_equal 1, calls
    end

    def test_binding_restores_nil_and_false_after_exceptions
      variable = local_var_class.new(:default)
      [nil, false].each do |original|
        variable.value = original
        assert_raises(RuntimeError) { variable.bind(:temporary) { raise "binding failed" } }

        original.nil? ? assert_nil(variable.value) : assert_same(original, variable.value)
      end
    end

    def test_bind_without_a_block_does_not_initialize_or_change_the_value
      calls = 0
      variable = local_var_class.new { calls += 1 }

      assert_nil variable.bind(:temporary)
      assert_equal 0, calls
      assert_equal 1, variable.value
    end

    def test_freezing_prevents_assignment_and_binding
      variable = local_var_class.new(:default)

      refute_predicate variable, :frozen?
      assert_same variable, variable.freeze
      assert_predicate variable, :frozen?
      assert_raises(FrozenError) { variable.value = :changed }
      assert_raises(FrozenError) { variable.bind(:changed) { flunk "frozen variable was bound" } }
      assert_equal :default, variable.value
    end

    def test_mutable_defaults_keep_their_identity
      default = []
      variable = local_var_class.new(default)

      assert_same default, variable.value
      refute_predicate default, :frozen?
      refute Farce::Ractor.shareable?(variable) if Internal.native_ractors?
    end

    def test_values_are_isolated_between_ractors
      variable = local_var_class.new(:default)
      variable.value = :main

      assert Farce::Ractor.shareable?(variable)
      worker = Farce::Ractor.new(variable) do |shared|
        initial = shared.value
        shared.value = :worker
        [initial, shared.value].freeze
      end

      assert_equal %i[default worker], ractor_value(worker)
      assert_equal :main, variable.value
    end

    def test_shareable_default_block_is_evaluated_independently_in_each_ractor
      calls = Farce::Counter.new
      variable = local_var_class.new { calls.increment.value }

      assert Farce::Ractor.shareable?(variable)
      assert_equal 1, variable.value
      worker = Farce::Ractor.new(variable) { |shared| [shared.value, shared.value].freeze }

      assert_equal [2, 2], ractor_value(worker)
      assert_equal 1, variable.value
      assert_equal 2, calls.value
    end

    def test_cannot_be_marshaled
      assert_raises(TypeError) { Marshal.dump(local_var_class.new) }
    end
  end
end
