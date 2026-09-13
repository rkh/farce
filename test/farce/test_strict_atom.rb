# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "internal/test_atom"

module Farce
  class TestStrictAtom < Internal::TestAtom
    def atom_class = Strict::Atom

    def test_public_type_and_shareability
      atom = atom_class.new

      assert_equal Abstract::Atom, atom_class.superclass
      assert_kind_of Abstract::Atom, atom
      assert_kind_of Abstract::Value, atom
      refute_kind_of Abstract::WeakAtom, atom
      assert_predicate atom, :frozen?
      assert_predicate atom, :ractor_shareable?
      assert Ractor.shareable?(atom)
      refute_respond_to atom, :mode
    end

    def test_direct_storage_and_strong_retention
      atom = Thread.new { atom_class.new(Object.new.freeze) }.value
      3.times { RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start }
      value = atom.value

      refute_nil value
      assert_same value, atom.get
      envelope = Envelope.new(:payload)

      assert_same envelope, atom.store(envelope)
      assert_same envelope, atom.value
      assert_equal :payload, atom.unwrap
    end

    def test_rejects_modes
      assert_raises(ArgumentError) { atom_class.new(mode: :copy) }
      atom = atom_class.new

      assert_raises(ArgumentError) { atom.store(:value, mode: :copy) }
      assert_raises(ArgumentError) { atom.swap(:value, mode: :copy) }
      assert_raises(ArgumentError) { atom.store_if_absent(mode: :copy) { :value } }
      assert_raises(ArgumentError) { atom.update(mode: :copy) { :value } }
      assert_raises(ArgumentError) { atom.upsert(:value, mode: :copy) { :value } }
      assert_raises(ArgumentError) { atom.compare_and_set(nil, :value, mode: :copy) }
    end

    def test_rejects_explicitly_unshareable_values_and_recovers
      rejected = Unshared::Queue.new
      atom = atom_class.new

      assert_raises(Ractor::IsolationError) { atom_class.new(rejected) }
      assert_raises(Ractor::IsolationError) { atom.value = rejected }
      assert_raises(Ractor::IsolationError) { atom.store(rejected) }
      assert_raises(Ractor::IsolationError) { atom.swap(rejected) }
      assert_raises(Ractor::IsolationError) { atom.store_if_absent { rejected } }
      assert_raises(Ractor::IsolationError) { atom.update { rejected } }
      assert_raises(Ractor::IsolationError) { atom.upsert(rejected) { :value } }
      assert_raises(Ractor::IsolationError) { atom.compare_and_set(nil, rejected) }
      assert_raises(Ractor::IsolationError) { atom.compare_and_set(rejected, nil) }
      assert_raises(Ractor::IsolationError) { atom.wait_until_changed(rejected, timeout: 0) }
      assert_nil atom.value
      atom.store(:value)

      assert_raises(Ractor::IsolationError) { atom.upsert(nil) { rejected } }
      assert_equal :value, atom.value
      assert_equal(:recovered, atom.update { :recovered })
    end
  end
end
