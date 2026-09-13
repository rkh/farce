# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_atom"

module Farce
  module Internal
    class TestWeakAtom < TestAtom
      include Helpers::InternalTestHelpers

      def atom_class = WeakAtom
      def test_timeout = 5

      def test_default_and_shareability
        atom = atom_class.new

        assert_nil atom.value
        refute_predicate atom, :compare_by_identity?
        if shareable_atom?
          assert_predicate atom, :frozen?
          assert Ractor.shareable?(atom)
        elsif RUBY_ENGINE == "ruby"
          refute Ractor.shareable?(atom)
        end
      end

      def test_live_value_remains_reachable
        value = shared_string("value")
        atom = atom_class.new(value)

        3.times { collect_garbage }

        assert_same value, atom.value
      end

      def test_compaction_preserves_a_live_value
        value = shared_string("value")
        atom = atom_class.new(value)

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

      def test_false_is_present_and_nil_is_absent
        atom = atom_class.new(false)
        called = false

        assert_same(false, atom.store_if_absent { called = true })
        refute called
        assert atom.compare_and_set(false, nil)
        assert_nil atom.value
        assert_equal(:replacement, atom.store_if_absent { :replacement })
        assert atom.compare_and_set(:replacement, false)
        assert_same false, atom.value
      end

      def test_nonlocal_exit_releases_the_update
        atom = atom_class.new(:original)
        result = catch(:cancel) do
          atom.update { throw :cancel, :cancelled }
        end

        assert_equal :cancelled, result
        assert_equal :original, atom.value
        assert_equal :replacement, atom.update(timeout: 0) { :replacement }
      end

      def test_updates_from_multiple_ractors
        skip "atom is unshared" unless shareable_atom?
        atom = atom_class.new(0)
        workers = 4.times.map do
          Ractor.new(atom) do |shared|
            local = []
            25.times do
              shared.update do |old|
                local << true
                old + 1
              end
            end
            local.length
          end
        end

        workers.each { assert_equal 25, ractor_value(it) }

        assert_equal 100, atom.value
      end

      class ObservedWaitValue
        def initialize(entered)
          @entered = entered
          freeze
        end

        def ==(other)
          @entered.push(:compared)
          other == :expected
        end
      end

      def test_observer_finishes_after_collection_and_a_store
        entered = Queue.new
        atom = Thread.new { atom_class.new(ObservedWaitValue.new(entered)) }.value
        waiter = Thread.new { atom.wait_until_changed(:expected) }
        begin
          assert_equal :compared, entered.pop(timeout: 2)
          10.times do
            collect_garbage
            Thread.pass
          end
          atom.store(:changed)

          assert waiter.join(2), "observer remained blocked after storing a new value"
          assert_includes [nil, :changed], waiter.value
        ensure
          waiter.kill if waiter.alive?
          waiter.join
        end
      end

      private

      def build_weak_atom
        # Build the atom on a disposable native stack. CRuby conservatively
        # scans C stack slots, so a stale VALUE can otherwise retain the value.
        Thread.new do
          value = Object.new
          value.freeze if shareable_atom?
          atom_class.new(value)
        end.value
      end

      def collect_garbage
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
      end

      def assert_collects_value(atom)
        20.times do
          2_000.times { Object.new }
          collect_garbage
          return assert_nil(atom.value) if atom.value.nil?
          sleep 0.01
        end

        flunk "weak atom value remained reachable after repeated full collections"
      end
    end
  end
end
