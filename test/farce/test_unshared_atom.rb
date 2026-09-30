# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestUnsharedAtom < Test
    def test_retains_values_directly_and_supports_atomic_operations
      value = []
      atom = Unshared::Atom.new(value)

      assert_same value, atom.value
      assert_same value, atom.get
      refute_predicate atom, :ractor_shareable?
      refute_respond_to atom, :freeze
      assert_equal :stored, atom.store(:stored)
      assert_equal :stored, atom.swap(:swapped)
      assert atom.compare_and_set(:swapped, :compared)
      refute atom.compare_and_set(:missing, :ignored)
      assert_equal(:updated, atom.update { :updated })
      assert_equal :upserted, atom.upsert(:initial) { :upserted }
      atom.value = nil

      assert_equal(:absent, atom.store_if_absent { :absent })
      assert_equal(:absent, atom.store_if_absent { flunk })
      assert_equal :absent, atom.wait_until_non_nil(timeout: 0)
      assert_equal :timeout, atom.wait_until_changed(:absent, timeout: 0) { :timeout }
    end

    def test_comparison_policy
      first = [1]
      equal = [1]
      identity = Unshared::Atom.new(first, compare_by_identity: true)

      assert_predicate identity, :compare_by_identity?
      refute identity.compare_and_set(equal, :wrong)
      assert identity.compare_and_set(first, :right)
      equality = Unshared::Atom.new(first)

      assert equality.compare_and_set(equal, :right)
      assert_raises(ArgumentError) { Unshared::Atom.new(compare_by_identity: nil) }
    end

    def test_failed_update_preserves_the_value
      atom = Unshared::Atom.new(:initial)
      assert_raises(RuntimeError) { atom.update { raise "failure" } }
      assert_equal :initial, atom.value
      assert_equal(:recovered, atom.update { :recovered })
    end

    def test_copy_has_independent_storage
      atom = Unshared::Atom.new(:initial)
      [atom.dup, atom.clone].each do |copy|
        copy.value = :changed

        assert_equal :initial, atom.value
        assert_equal :changed, copy.value
      end
    end

    def test_serializes_thread_updates
      atom = Unshared::Atom.new(0)
      threads = 4.times.map { Thread.new { 50.times { atom.update { it + 1 } } } }
      threads.each(&:value)

      assert_equal 200, atom.value
    end
  end
end
