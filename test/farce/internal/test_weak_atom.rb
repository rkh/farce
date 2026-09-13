# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestWeakAtom < Test
      include Helpers::InternalTestHelpers

      def setup
        skip "native weak-atom support is unavailable" unless Internal.const_defined?(:WeakAtom, false)
      end

      def test_default_and_shareability
        atom = WeakAtom.new

        assert_nil atom.value
        refute_predicate atom, :compare_by_identity?
        assert_predicate atom, :frozen?
        assert Ractor.shareable?(atom)
      end

      def test_live_value_remains_reachable
        value = shared_string("value")
        atom = WeakAtom.new(value)

        3.times { GC.start }

        assert_same value, atom.value
      end

      def test_compaction_preserves_a_live_value
        value = shared_string("value")
        atom = WeakAtom.new(value)

        GC.compact if GC.respond_to?(:compact)

        assert_same value, atom.value
      end

      def test_collected_value_reverts_to_nil
        atom = build_weak_atom

        assert_collects_value(atom)
      end

      def test_can_store_a_new_value_after_collection
        atom = build_weak_atom

        assert_collects_value(atom)
        replacement = shared_string("replacement")

        assert_same replacement, atom.store(replacement)
        assert_same replacement, atom.value
      end

      private

      def build_weak_atom(value = Object.new)
        # Build the atom on a disposable native stack. CRuby conservatively
        # scans C stack slots, so a stale VALUE can otherwise retain the value.
        Thread.new do
          WeakAtom.new(Ractor.make_shareable(value))
        end.value
      end

      def assert_collects_value(atom)
        20.times do
          2_000.times { Object.new }
          GC.start
          return assert_nil(atom.value) if atom.value.nil?
        end

        flunk "weak atom value remained reachable after repeated full collections"
      end
    end
  end
end
