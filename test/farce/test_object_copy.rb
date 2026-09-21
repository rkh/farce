# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestObjectCopy < Test
    ATOMS = [Atom, Strict::Atom, Strict::WeakAtom, Unshared::WeakAtom, Local::Atom, Local::WeakAtom].freeze
    VECTORS = [Vector, Strict::Vector, Unshared::Vector, Local::Vector].freeze

    def test_atoms_copy_current_value_into_independent_storage
      ATOMS.each do |type|
        source = type.new(:initial, compare_by_identity: true)
        source.value = :current
        copies(source).each do |copy|
          assert_equal :current, copy.value
          assert_predicate copy, :compare_by_identity?
          copy.value = :changed

          assert_equal :current, source.value
        end
      end
    end

    def test_vectors_copy_current_slots_into_independent_storage
      VECTORS.each do |type|
        source = type.new([:initial], compare_by_identity: true)
        source[0] = :current
        copies(source).each do |copy|
          assert_equal :current, copy[0]
          assert_predicate copy, :compare_by_identity?
          copy.clear

          assert_equal 1, source.size
        end
      end
    end

    def test_flags_copy_current_value
      [Flag, Local::Flag].each do |type|
        source = type.new(false)
        source.set
        copies(source).each do |copy|
          assert_predicate copy, :value
          copy.value = false

          assert_predicate source, :value
        end
      end
    end

    def test_counters_copy_current_and_initial_values
      [Counter, Local::Counter].each do |type|
        source = type.new(3)
        source.increment(4)
        copies(source).each do |copy|
          refute_same source, copy
          assert_equal 7, copy.value
          copy.reset

          assert_equal 3, copy.value
          assert_equal 7, source.value
        end
      end
    end

    def test_coordination_objects_reject_copies
      objects = [Scheduler.new, Pool.new, Lock.new, ReadWriteLock.new, Signal.new,
                 Exchanger.new, Strict::Exchanger.new, Port.new,
                 Lease.new { Object.new }, Unshared::Lease.new { Object.new }, Local::Lease.new { Object.new }]
      [LeasePool, Unshared::LeasePool, Local::LeasePool].each do |type|
        objects << type.new(max_size: 1) { Object.new }
      end
      objects.each do |object|
        refute_predicate object, :duplicable?
        assert_raises(TypeError) { object.dup }
        assert_raises(TypeError) { object.clone }
        assert_raises(TypeError) { object.clone(freeze: false) }
      end
    ensure
      objects&.each { it.close if it.is_a?(Abstract::Scheduler) || it.is_a?(Port) }
    end

    def test_explicit_unfrozen_clones_keep_independent_storage
      [Atom.new(1), Strict::WeakAtom.new(1), Vector.new([1]), Flag.new(true), Counter.new(1),
       Local::Atom.new(1), Local::Vector.new([1]), Local::Flag.new(true), Local::Counter.new(1)].each do |source|
        copy = source.clone(freeze: false)

        refute_predicate copy, :frozen?
        refute_same source, copy
        if source.is_a?(Abstract::Vector)
          copy.clear

          assert_equal 1, source.size
        else
          copy.value = source.is_a?(Abstract::Flag) ? false : 2

          assert_equal(source.is_a?(Abstract::Flag) || 1, source.value)
        end
      end
    end

    def test_mode_copies_do_not_claim_or_rewrap_values
      [Atom, Vector].each do |type|
        source = type.new(nil, mode: :move)
        type == Atom ? source.instance_variable_get(:@atom).store(Envelope::Move.new([])) : source.push([])
        backend = source.instance_variable_get(type == Atom ? :@atom : :@vector)
        envelope = type == Atom ? backend.value : backend[0]
        copy = source.dup

        assert_equal :move, copy.mode
        refute_predicate envelope, :claimed? if envelope.is_a?(Envelope)
        copied_backend = copy.instance_variable_get(type == Atom ? :@atom : :@vector)

        assert_same envelope, type == Atom ? copied_backend.value : copied_backend[0]
      end
    end

    def test_mode_manager_copies_remain_shareable_independent_descriptors
      source = ModeManager.new(mode: :copy)
      source_envelope = source.wrap([])

      [source.dup, source.clone, source.clone(freeze: false), source.clone(freeze: true)].each do |copy|
        refute_same source, copy
        assert_equal :copy, copy.mode
        assert_predicate copy, :frozen?
        assert Ractor.shareable?(copy)
        assert_predicate copy, :ractor_shareable?
        assert_same source_envelope, copy.unwrap(source_envelope)

        copy_envelope = copy.wrap([])

        assert_same copy_envelope, source.unwrap(copy_envelope)
        assert_equal [], copy.unwrap(copy_envelope)
      end
    end

    def test_local_copies_preserve_scope_defaults
      [Local::Atom, Local::WeakAtom, Local::Counter].each do |type|
        source = type.new(1, scope: :fiber)
        source.value = 2
        copy = source.dup

        assert_equal 2, copy.value
        assert_equal [1, 1], Fiber.new { [source.value, copy.value] }.resume
        assert_equal 2, source.value
      end
    end

    def test_lazy_copies_share_evaluation_in_each_scope
      [Lazy, Local::Lazy].each do |type|
        source = type.new { [].freeze }
        copy = source.dup

        assert_predicate copy, :duplicable?
        assert Ractor.shareable?(copy)
        assert_same source.value, copy.value
        assert Fiber.new { source.value.equal?(copy.value) }.resume
      end
    end

    def test_weak_reference_copies_never_copy_the_target
      target = Object.new
      def target.dup = raise("target must not be duplicated")
      def target.clone(*) = raise("target must not be cloned")

      [WeakValue, WeakRef].each do |type|
        source = type.new(target)

        assert_predicate source, :duplicable?
        [source.dup, source.clone, source.clone(freeze: false)].each do |copy|
          assert_same target, type == WeakRef ? copy.__getobj__ : copy.value
        end
      end
    end

    def test_envelopes_reject_copies_without_claiming_payloads
      [Envelope::Copy, Envelope::Move, Envelope::Local, Envelope::Share].each do |type|
        source = type.new(type == Envelope::Share ? :value : [])

        refute_predicate source, :duplicable?
        assert_raises(TypeError) { source.dup }
        assert_raises(TypeError) { source.clone }
        refute_predicate source, :claimed? if type == Envelope::Move
      end
    end

    def test_copies_do_not_inherit_pending_updates
      (ATOMS.reject { it < Local::Scoped } + VECTORS.reject { it < Local::Scoped }).each do |type|
        vector = type < Abstract::Vector
        source = type.new(vector ? [:initial] : :initial)
        entered = ::Queue.new
        release = ::Queue.new
        worker = Thread.new do
          source.update(*(vector ? [0] : [])) do
            entered << true
            release.pop
            :original_update
          end
        end
        entered.pop
        copy = source.dup
        result = copy.update(*(vector ? [0] : []), timeout: 0) { :copy_update }

        assert_equal :copy_update, result
        assert_equal :initial, vector ? source[0] : source.value
        release << true
        worker.value

        assert_equal :copy_update, vector ? copy[0] : copy.value
        assert_equal :original_update, vector ? source[0] : source.value
      ensure
        release << true if worker&.alive?
        worker&.join
      end
    end

    def test_weak_atoms_keep_weak_retention_after_copying
      [Strict::WeakAtom, Unshared::WeakAtom, Local::WeakAtom].each do |type|
        source, copy = Thread.new do
          original = type.new
          original.value = Object.new.freeze
          [original, original.dup]
        end.value
        20.times do
          2_000.times { Object.new }
          RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
          break if source.value.nil? && copy.value.nil?
          sleep 0.01
        end

        assert_nil source.value
        assert_nil copy.value
      end
    end

    def test_nil_weak_value_copies
      source = WeakValue.new(nil)

      assert_nil source.dup.value
      assert_nil source.clone.value
      assert_predicate source.dup, :alive?
    end

    def test_other_public_copy_policies
      [ModeManager.new, Config.new].each do |source|
        assert_predicate source, :duplicable?
        assert_instance_of source.class, source.dup
      end
      source = Resolv::DNS.new

      refute_predicate source, :duplicable?
      assert_raises(TypeError) { source.dup }
      assert_raises(TypeError) { source.clone }
    ensure
      source.close if source.is_a?(Resolv::DNS)
    end

    def test_counter_clones_preserve_numeric_identity
      [Counter, Local::Counter].each do |type|
        source = type.new(1).clone(freeze: false)
        copy = source.clone

        assert_kind_of Numeric, copy
        refute_same source, copy
        assert_raises(ArgumentError) { source.clone(freeze: :invalid) }
      end
    end

    def test_counter_copy_hook_exceptions_propagate
      type = Class.new(Counter) do
        private def initialize_copy(other)
          super
          raise ArgumentError, "copy hook failure"
        end
      end
      source = type.new

      assert_equal "copy hook failure", assert_raises(ArgumentError) { source.dup }.message
      assert_equal "copy hook failure", assert_raises(ArgumentError) { source.clone }.message
    end

    private

    def copies(source)
      assert_predicate source, :duplicable?
      [source.dup, source.clone].each do |copy|
        assert_instance_of source.class, copy
        assert Ractor.shareable?(copy) if source.is_a?(Shareable)
      end
    end
  end
end
