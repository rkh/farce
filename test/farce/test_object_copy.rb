# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestObjectCopy < Test
    include Helpers::InternalTestHelpers

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
      objects = [Scheduler.new, Pool.new, Signal.new,
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

    def test_lock_copies_are_fresh_unlocked_instances
      type = Class.new(Lock) do
        def marker = :preserved

        def initialize(marker)
          raise ArgumentError, "unexpected marker" unless marker == :preserved

          super()
        end
      end
      source = type.new(:preserved)
      entered = ::Queue.new
      release = ::Queue.new
      worker = Thread.new do
        source.synchronize do
          entered << true
          release.pop
        end
      end
      entered.pop

      copies(source).each do |copy|
        assert_equal :preserved, copy.marker
        refute_predicate copy, :locked?
        assert_equal(:acquired, copy.synchronize { :acquired })
        assert_predicate source, :locked?
        refute_predicate copy, :frozen?
        assert_raises(TypeError) { copy.freeze }
      end
      assert_raises(TypeError) { source.clone(freeze: true) }
      unfrozen = source.clone(freeze: false)

      refute_predicate unfrozen, :frozen?
      refute_predicate unfrozen, :locked?
      assert_equal :preserved, unfrozen.marker
      assert_equal(:acquired, unfrozen.synchronize { :acquired })
      assert_predicate source, :locked?
    ensure
      release&.push(true)
      worker&.join
    end

    def test_read_write_lock_copies_exclude_lock_state
      source = ReadWriteLock.new

      source.with_read_lock do
        copies(source).each do |copy|
          assert_equal(:written, copy.with_write_lock { :written })
        end
        unfrozen = source.clone(freeze: false)

        refute_predicate unfrozen, :frozen?
        assert_equal(:written, unfrozen.with_write_lock { :written })
      end
      source.with_write_lock do
        copies(source).each do |copy|
          assert_equal(:read, copy.with_read_lock { :read })
        end
      end
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

    def test_copy_envelopes_duplicate_the_stored_snapshot
      manager = ModeManager.new
      source = Envelope::Copy.new([["stored"]], manager)
      local_view = source.value
      local_view << ["caller mutation"]

      copies(source).each do |copy|
        assert_same manager, copy.auto_unwrap
        assert_equal [["stored"]], copy.value
        refute_same local_view, copy.value
        assert source.same_value?(copy)
        copy.value << ["copy mutation"]

        assert_equal [["stored"], ["caller mutation"]], source.value
      end
      unfrozen = source.clone(freeze: false)

      refute_predicate unfrozen, :frozen?
      assert_equal [["stored"]], unfrozen.value
      assert_same manager, unfrozen.auto_unwrap
      assert source.same_value?(unfrozen)
      unfrozen.value << ["unfrozen caller mutation"]
      second_generation = unfrozen.dup

      assert_equal [["stored"]], second_generation.value
      assert unfrozen.same_value?(second_generation)
      assert source.same_value?(second_generation)
      assert_same local_view, source.value
    end

    def test_local_envelope_copies_duplicate_the_payload_once
      calls = []
      payload_type = Class.new(Array) do
        define_method(:initialize_copy) do |other|
          calls << :dup
          super(other)
        end
      end
      nested = []
      payload = payload_type.new([nested])
      manager = ModeManager.new
      source = Envelope::Local.new(payload, manager)

      copies(source).each do |copy|
        assert_same manager, copy.auto_unwrap
        refute_same payload, copy.value
        assert_same nested, copy.value.first
      end
      unfrozen = source.clone(freeze: false)

      refute_predicate unfrozen, :frozen?
      refute_same payload, unfrozen.value
      assert_same nested, unfrozen.value.first
      assert_same manager, unfrozen.auto_unwrap
      assert_equal %i[dup dup dup], calls
    end

    def test_copy_envelope_uses_the_stored_snapshot_in_each_ractor
      source = Envelope::Copy.new(["stored"])
      local_view = source.value
      local_view << "local"
      worker = Ractor.new(source) do |envelope|
        remote_view = envelope.value
        remote_view << "remote"
        duplicate = envelope.dup
        [duplicate.value, envelope.value].map { Ractor.make_shareable(it, copy: true) }.freeze
      end

      assert_equal [["stored"], %w[stored remote]], ractor_value(worker)
      assert_equal %w[stored local], source.value
      assert_same local_view, source.value
    end

    def test_local_envelope_copy_rejects_nonowners_before_payload_dup
      payload = Object.new
      def payload.dup = raise("payload dup must not be called")
      source = Envelope::Local.new(payload)
      worker = Ractor.new(source) do |envelope|
        envelope.dup
      rescue StandardError => e
        [e.class.name, e.message].freeze
      end

      assert_equal(
        ["Farce::Envelope::AlreadyClaimed", "envelope has already been claimed by another Ractor"],
        ractor_value(worker),
      )
    end

    def test_share_envelope_copies_keep_payload_and_manager_identity
      payload = Ractor.make_shareable(["shared"], copy: true)
      manager = ModeManager.new
      source = Envelope::Share.new(payload, manager)

      copies(source).each do |copy|
        refute_same source, copy
        assert_same payload, copy.value
        assert_same manager, copy.auto_unwrap
      end
      unfrozen = source.clone(freeze: false)

      refute_same source, unfrozen
      refute_predicate unfrozen, :frozen?
      assert_same payload, unfrozen.value
      assert_same manager, unfrozen.auto_unwrap
    end

    def test_move_envelopes_still_reject_copies_without_claiming_payloads
      source = Envelope::Move.new([])

      refute_predicate source, :duplicable?
      assert_raises(TypeError) { source.dup }
      assert_raises(TypeError) { source.clone }
      assert_raises(TypeError) { source.clone(freeze: false) }
      refute_predicate source, :claimed?
    end

    def test_reference_copies_duplicate_the_backing_value_once
      payload = []
      copies = []
      value_type = Class.new do
        include Abstract::Value

        attr_accessor :value

        define_method(:initialize) { |value| @value = value }
        define_method(:dup) do
          copies << :dup
          super()
        end
        define_method(:clone) do |**options|
          copies << :clone
          super(**options)
        end
      end
      value = value_type.new(payload)
      source = Reference.new(value)
      duplicate = source.dup
      clone = source.clone

      assert_operator Reference, :===, duplicate
      assert_operator Reference, :===, clone
      refute_same source, duplicate
      refute_same source, clone
      assert_same payload, Reference.deref(duplicate).value
      assert_same payload, Reference.deref(clone).value
      refute_same value, Reference.deref(duplicate)
      refute_same value, Reference.deref(clone)
      assert_equal %i[dup clone], copies
    end

    def test_reference_copy_preserves_generated_and_deep_reference_classes
      factory_calls = []
      value_type = Class.new do
        include Abstract::Value

        attr_reader :value

        define_method(:initialize) do |value|
          factory_calls << value
          @value = value
        end
      end
      generated = Reference[value_type]
      source = generated.new(:generated)
      duplicate = source.dup

      assert_operator generated, :===, duplicate
      assert_equal [:generated], factory_calls
      refute_same Reference.deref(source), Reference.deref(duplicate)

      deep = Reference.new(value_type.new(value_type.new(:deep)), deep: true)
      deep_copy = deep.dup

      assert_operator Reference, :===, deep_copy
      assert_same Kernel.instance_method(:class).bind_call(deep),
        Kernel.instance_method(:class).bind_call(deep_copy)
      assert_equal :deep, deep_copy.itself
      refute_same Reference.deref(deep), Reference.deref(deep_copy)
    end

    def test_lazy_reference_copy_does_not_evaluate_factory
      source = LazyRef.new { raise "factory must not be called" }
      copy = source.dup
      source_lazy = Reference.deref(source)
      copied_lazy = Reference.deref(copy)

      refute_same source_lazy, copied_lazy
      assert_same source_lazy.instance_variable_get(:@atom), copied_lazy.instance_variable_get(:@atom)
    end

    def test_reference_clone_preserves_outer_singleton_methods_without_freezing_payload
      payload = []
      value = Local::Atom.new(payload)
      source = Reference.new(value)
      def source.copy_marker = :preserved
      Kernel.instance_method(:freeze).bind_call(source)

      duplicate = source.dup
      copy = source.clone

      assert_raises(NoMethodError) { duplicate.copy_marker }
      assert_equal :preserved, copy.copy_marker
      assert Kernel.instance_method(:frozen?).bind_call(copy)
      refute_predicate payload, :frozen?
      refute_same value, Reference.deref(copy)
    end

    def test_reference_copies_run_outer_copy_hooks
      calls = []
      type = Class.new(Reference) do
        attr_reader :copied

        define_method(:initialize_copy) do |other|
          calls << :copy
          super(other)
          @copied = true
        end
      end
      source = type.new(Local::Atom.new([]))

      assert source.dup.copied
      assert source.clone.copied
      assert_equal %i[copy copy], calls

      rejecting = Class.new(Reference) do
        private def initialize_copy(other)
          super
          ::Kernel.raise(::ArgumentError, "outer copy hook failure")
        end
      end.new(Local::Atom.new([]))

      assert_equal "outer copy hook failure", assert_raises(ArgumentError) { rejecting.dup }.message
      assert_equal "outer copy hook failure", assert_raises(ArgumentError) { rejecting.clone }.message
    end

    def test_reference_clone_does_not_forward_outer_freeze_to_backing_value
      options = []
      value_type = Class.new do
        include Abstract::Value

        attr_reader :value

        define_method(:initialize) { |value| @value = value }
        define_method(:clone) do |**keywords|
          options << keywords
          super(**keywords)
        end
      end
      source = Reference.new(value_type.new([]))

      source.clone
      source.clone(freeze: false)

      assert_equal [{}, {}], options
    end

    def test_reference_copy_propagates_backing_copy_errors
      value_type = Class.new do
        include Abstract::Value

        def value = :value
        def dup = raise(ArgumentError, "backing dup failure")
        def clone(**) = raise(ArgumentError, "backing clone failure")
      end
      source = Reference.new(value_type.new)

      assert_equal "backing dup failure", assert_raises(ArgumentError) { source.dup }.message
      assert_equal "backing clone failure", assert_raises(ArgumentError) { source.clone }.message
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
