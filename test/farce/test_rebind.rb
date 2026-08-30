# frozen_string_literal: true

require_relative "../setup"

module Farce
  class TestRebind < Test
    def test_rebinds_block_to_given_self
      rebound = Farce.rebind(self: 42) { self * 10 }

      assert_equal 420, rebound.call
    end

    def test_rebinds_proc_to_given_self
      original = proc { self[:answer] }
      rebound = Farce.rebind(original, self: { answer: 42 })

      assert_equal 42, rebound.call
      refute_same original, rebound
    end

    def test_rebound_proc_preserves_parameters_and_forwards_blocks
      original = proc { |key, default = nil, *rest, required:, optional: nil, **kwargs, &fallback|
        [fetch(key, default || fallback.call), rest, required, optional, kwargs]
      }

      rebound = Farce.rebind(original, self: { present: 42 })

      assert_equal original.parameters, rebound.parameters
      assert_equal [42, [], 1, 2, { extra: 3 }], rebound.call(:present, required: 1, optional: 2, extra: 3) { 0 }
      assert_equal [9, [], 1, nil, {}], rebound.call(:missing, required: 1) { 9 }
    end

    def test_preserves_proc_lambda_state_by_default
      proc_rebound = Farce.rebind(proc { self }, self: 42)
      lambda_rebound = Farce.rebind(-> { self }, self: 42)

      refute_predicate proc_rebound, :lambda?
      assert_predicate lambda_rebound, :lambda?
    end

    def test_can_force_block_proc_to_lambda
      rebound = Farce.rebind(proc { self }, self: 42, lambda: true)

      assert_predicate rebound, :lambda?
      assert_equal 42, rebound.call
    end

    def test_can_force_block_lambda_to_proc
      rebound = Farce.rebind(-> { self }, self: 42, lambda: false)

      refute_predicate rebound, :lambda?
      assert_equal 42, rebound.call
    end

    def test_preserves_frozen_proc_state
      original = proc { self }.freeze

      assert_predicate Farce.rebind(original, self: 42), :frozen?
    end

    def test_returns_same_proc_when_receiver_is_unchanged
      original = proc { self }

      assert_same original, Farce.rebind(original, self: self)
    end

    def test_returns_non_rebindable_proc_unchanged
      original = :to_s.to_proc

      assert_same original, Farce.rebind(original, self: 42)
      assert_same original, Farce.rebind(original, self: 42, lambda: false)
    end

    def test_rebinds_bound_method_to_new_self
      original = "hello".method(:upcase)
      rebound = Farce.rebind(original, self: "goodbye")

      assert_instance_of Method, rebound
      assert_equal "GOODBYE", rebound.call
    end

    def test_returns_same_bound_method_when_receiver_is_unchanged
      original = "hello".method(:upcase)

      assert_same original, Farce.rebind(original, self: original.receiver)
    end

    def test_binds_unbound_method_to_given_self
      rebound = Farce.rebind(String.instance_method(:upcase), self: "hello")

      assert_instance_of Method, rebound
      assert_equal "HELLO", rebound.call
    end

    def test_rejects_missing_bindable
      error = assert_raises(ArgumentError) { Farce.rebind }

      assert_equal "tried to create Proc object without a block", error.message
    end

    def test_rejects_more_than_one_block
      error = assert_raises(ArgumentError) { Farce.rebind(proc {}, &:itself) }

      assert_equal "more than one block given", error.message
    end

    def test_rejects_invalid_bindable
      error = assert_raises(ArgumentError) { Farce.rebind(42) }

      assert_equal "invalid bindable: 42", error.message
    end

    def test_rejects_unknown_self_option
      error = assert_raises(ArgumentError) { Farce.rebind(proc {}, receiver: 42) }

      assert_equal "unknown keyword: :receiver", error.message
    end

    def test_rejects_multiple_self_option
      error = assert_raises(ArgumentError) { Farce.rebind(proc {}, receiver: 42, binding: binding) }

      assert_equal "unknown keywords: :receiver, :binding", error.message
    end
  end
end
