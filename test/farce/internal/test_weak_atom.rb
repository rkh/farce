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
          refute_predicate atom, :frozen?
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

      def test_timeout_conversion_that_freezes_the_atom_rejects_no_op_store_if_absent
        atom = atom_class.new(:present)

        assert_raises(FrozenError) do
          atom.store_if_absent(timeout: FreezingTimeout.new(atom)) { :replacement }
        end
        assert_equal :present, atom.value
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
        return unless shareable_atom?
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
        ready = Thread::Queue.new
        release = Thread::Queue.new
        holder = Thread.new do
          # Retain the value until the observer has compared it. Clear this
          # disposable stack before checking whether the value is collectible.
          values = [ObservedWaitValue.new(entered)]
          ready.push(atom_class.new(values.first))
          release.pop
          values.clear
          nil
        end
        atom = ready.pop
        collect_garbage
        waiter = Thread.new { atom.wait_until_changed(:expected) }

        assert_equal :compared, entered.pop(timeout: 2)
        release.push(true)

        assert holder.join(2), "value holder did not release its reference"
        10.times do
          collect_garbage
          Thread.pass
        end
        atom.store(:changed)

        assert waiter.join(2), "observer remained blocked after storing a new value"
        assert_includes [nil, :changed], waiter.value
      ensure
        waiter&.kill if waiter&.alive?
        waiter&.join
        holder&.kill if holder&.alive?
        holder&.join
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
          # Read on a disposable stack so a live value observed on one attempt
          # cannot remain in a conservative GC root during the next collection.
          collected = Thread.new { atom.value.nil? }.value
          return assert_nil(atom.value) if collected
          sleep 0.01
        end

        flunk "weak atom value remained reachable after repeated full collections"
      end
    end
  end
end
