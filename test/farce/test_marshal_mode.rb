# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMarshalMode < Test
    include Helpers::InternalTestHelpers

    class CountingPayload
      DUMPS = Counter.new
      LOADS = Counter.new

      attr_reader :value

      def initialize(value) = @value = value

      def marshal_dump
        DUMPS.increment
        value
      end

      def marshal_load(value)
        LOADS.increment
        @value = value
      end
    end

    def test_envelope_factory_selects_marshal_and_preserves_shareable_values
      source = Unshared::Map.new({ items: [] })
      envelope = Envelope.new(source, mode: :marshal, move: true, local: true)

      assert_instance_of Envelope::Marshal, envelope
      assert Ractor.shareable?(envelope)
      assert_predicate envelope, :frozen?
      assert_same envelope, envelope.claim
      assert_same envelope, envelope.claim!
      assert_predicate envelope, :claimed?
      assert_predicate envelope, :owned?
      assert_nil envelope.auto_unwrap
      assert_instance_of Envelope::Share, Envelope.new(:ready, mode: :marshal)
    end

    def test_serializes_once_and_loads_once_per_ractor
      dumps = CountingPayload::DUMPS.value
      loads = CountingPayload::LOADS.value
      source = CountingPayload.new([:before])
      envelope = Envelope::Marshal.new(source)
      source.value << :source_change

      assert_equal dumps + 1, CountingPayload::DUMPS.value
      assert_equal loads, CountingPayload::LOADS.value
      first = envelope.value

      assert_equal [:before], first.value
      assert_same first, envelope.value
      assert_equal loads + 1, CountingPayload::LOADS.value
      first.value << :local_change

      worker = Ractor.new(envelope) do |shared|
        received = shared.value
        [received.value, received.equal?(shared.value)]
      end

      assert_equal [[:before], true], ractor_value(worker)
      assert_equal dumps + 1, CountingPayload::DUMPS.value
      assert_equal loads + 2, CountingPayload::LOADS.value
      assert_equal %i[before local_change], first.value
    end

    def test_rebuilds_usable_unshared_storage_and_preserves_graph_aliases_and_cycles
      items = [:before]
      map = Unshared::Map.new({ items: })
      graph = [map, map, items]
      map[:graph] = graph
      envelope = Envelope::Marshal.new(graph)
      map[:items] << :source_change
      local = envelope.value
      local[0][:items] << :local_change

      assert_same local[0], local[1]
      assert_same local[2], local[0][:items]
      assert_same local, local[0][:graph]

      worker = Ractor.new(envelope) do |shared|
        received = shared.value
        rebuilt = received[0]
        before = rebuilt[:items].dup
        rebuilt[:items] << :remote_change
        rebuilt[:new] = [:usable]
        [before, rebuilt[:new], received.equal?(rebuilt[:graph]),
         rebuilt.equal?(received[1]), rebuilt[:items].equal?(received[2]), rebuilt.ractor_shareable?]
      end

      assert_equal [[:before], [:usable], true, true, true, false], ractor_value(worker)
      assert_equal %i[before local_change], local[0][:items]
      refute local[0].key?(:new)
      assert_equal %i[before source_change], map[:items]
    end

    def test_preserves_frozen_container_state
      source = Unshared::Vector.new([[]]).freeze
      copy = Envelope::Marshal.new(source).value

      assert_instance_of Unshared::Vector, copy
      assert_predicate copy, :frozen?
      assert_raises(FrozenError) { copy.push(:new) }
      copy.first << :local

      assert_empty source.first
      refute_predicate copy, :ractor_shareable?
    end

    def test_envelope_copies_reconstruct_the_original_snapshot
      manager = ModeManager.new(mode: :marshal)
      source = Envelope::Marshal.new(Unshared::Map.new({ items: [] }), manager)
      source.value[:items] << :local_change

      [source.dup, source.clone, source.clone(freeze: false)].each do |copy|
        assert_same manager, copy.auto_unwrap
        assert_empty copy.value[:items]
        refute_same source.value, copy.value
        copy.value[:items] << :copy_change

        assert_equal [:local_change], source.value[:items]
      end
    end

    def test_marshal_round_trip_restores_the_opened_value_and_manager
      manager = ModeManager.new(mode: :marshal)
      envelope = manager.wrap(Unshared::Map.new({ items: [] }))
      envelope.value[:items] << :local_change
      restored, restored_manager = ::Marshal.load(::Marshal.dump([envelope, manager]))

      assert_instance_of Envelope::Marshal, restored
      assert Ractor.shareable?(restored)
      assert_same restored_manager, restored.auto_unwrap
      assert_equal :marshal, restored_manager.mode
      assert_equal [:local_change], restored_manager.unwrap(restored)[:items]
      refute_same envelope.value, restored.value
    end

    def test_mode_manager_supports_defaults_and_per_value_overrides
      [ModeManager.new(mode: :marshal), ModeManager.new].each do |manager|
        source = Unshared::Map.new({ items: [] })
        options = manager.mode == :marshal ? {} : { mode: :marshal }
        envelope = manager.wrap(source, **options)
        source[:items] << :source_change

        assert_instance_of Envelope::Marshal, envelope
        assert_same manager, envelope.auto_unwrap
        assert_empty manager.unwrap(envelope)[:items]
        assert_same envelope, ModeManager.new(mode: :marshal).unwrap(envelope)
      end
      shared = Ractor.make_shareable([:ready])
      manager = ModeManager.new(mode: :marshal)

      assert_same shared, manager.wrap(shared)
      assert_same shared, manager.unwrap(shared)
    end

    def test_ports_support_defaults_overrides_and_unmanaged_envelopes
      [Port.new(mode: :marshal), Port.new].each do |port|
        source = Unshared::Map.new({ items: [] })
        options = port.mode == :marshal ? {} : { mode: :marshal }
        port.send(source, **options)
        source[:items] << :source_change

        assert_empty port.receive[:items]
        explicit = Envelope::Marshal.new(source)
        port.send(explicit)

        assert_same explicit, port.receive
      ensure
        port&.close
      end
    end

    def test_serialization_failure_leaves_the_port_empty
      port = Port.new(mode: :marshal)
      source = Unshared::Map.new({ factory: -> { [] } })

      assert_raises(TypeError) { port.send(source) }
      assert_nil port.receive(timeout: 0)
      assert_raises(TypeError) { Envelope::Marshal.new(Queue.new) }
    ensure
      port&.close
    end

    def test_strong_collections_reconstruct_unshared_containers
      source = Unshared::TreeMap.new({ 1 => [] })
      map = Map.new(mode: :marshal)
      vector = Vector.new([], mode: :marshal)
      atom = Atom.new(source, mode: :marshal)
      map[:tree] = source
      vector.push(source)
      source[1] << :source_change

      [map[:tree], vector.first, atom.value].each do |copy|
        assert_instance_of Unshared::TreeMap, copy
        assert_empty copy[1]
        copy[2] = [:usable]

        assert_equal [:usable], copy[2]
        refute source.key?(2)
      end
    end

    def test_set_copies_retain_marshaled_entries_and_their_per_ractor_cache
      skip "mutable values use envelopes only with native Ractors" unless Internal.native_ractors?
      source = Set.new(mode: :local)
      element = []
      source.add(element, mode: :marshal)
      copy = source.dup
      element << :source_change

      assert_empty source.first
      assert_empty copy.first
      assert_same source.first, copy.first
      worker = Ractor.new(copy) do |set|
        set.first << :remote_change
        set.first.freeze
      end

      assert_equal [:remote_change], ractor_value(worker)
      assert_empty source.first
    end

    def test_identity_sets_reject_marshaling_nonshareable_elements
      return unless Internal.native_ractors?
      set = Set.new(mode: :marshal, compare_by_identity: true)

      error = assert_raises(ArgumentError) { set.add([]) }
      assert_equal "identity comparison cannot copy a non-shareable element", error.message
      assert_empty set
    end
  end
end
