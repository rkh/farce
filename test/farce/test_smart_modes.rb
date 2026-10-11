# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "date"
require "farce/integrations/date"

module Farce
  class TestSmartModes < Test
    include Helpers::InternalTestHelpers

    MODES = %i[smart smart_raise smart_copy smart_move].freeze

    class Payload
      include Unshareable::Copyable
      include Unshareable::Movable

      attr_accessor :value

      def initialize(value) = @value = value
    end

    class FailingCopyManager < ModeManager
      attr_reader :attempts

      def initialize(copy_error, marshal_failure: false)
        @copy_error = copy_error
        @marshal_failure = marshal_failure
        @attempts = Strict::Vector.new
        super(mode: :smart_copy)
      end

      def wrap(value, mode: nil)
        case mode
        when :copy
          @attempts << :copy
          raise @copy_error, "copy failed"
        when :marshal
          @attempts << :marshal
          raise TypeError, "marshal failed" if @marshal_failure
          :marshaled
        else super
        end
      end
    end

    def setup = @proxies = []

    def teardown
      get = Kernel.instance_method(:instance_variable_get)
      @proxies.each do |proxy|
        supervisor = get.bind_call(proxy, :@supervisor)
        get.bind_call(supervisor, :@queue).seal
      end
    end

    def test_mode_backed_containers_default_to_smart
      [Atom, Vector, Set, SortedSet, Map, WeakKeyMap, TreeMap,
       Queue, PriorityQueue, TimerQueue, Exchanger].each do |type|
        assert_equal :smart, type.new.mode, type.name
      end
      [LRUMap, LFUMap].each { |type| assert_equal :smart, type.new(max_size: 2).mode }
      assert_equal :smart, ModeManager.new.mode
      assert_equal :smart, Lazy.new { :value }.mode
      assert_equal :smart, Molecule.define(:item).default_mode
      assert_equal :smart, Molecule.define(:item).new.mode
      assert_equal :smart_copy, Port.new.mode
    end

    def test_default_storage_publishes_supported_values_and_rejects_unsupported_values
      [Atom.new, Vector.new, Map.new, Set.new, Queue.new].each do |container|
        source = [:ready]
        case container
        when Abstract::Value then container.value = source
        when Abstract::Map then container[:key] = source
        else container << source
        end
        assert Ractor.shareable?(source) if Internal.native_ractors?
        assert_raises(Ractor::IsolationError) do
          case container
          when Abstract::Value then container.value = Payload.new(:unsupported)
          when Abstract::Map then container[:key] = Payload.new(:unsupported)
          else container << Payload.new(:unsupported)
          end
        end
      end
    end

    def test_smart_identity_sets_use_the_prepared_element_for_membership
      return unless Internal.native_ractors?
      %i[smart smart_raise smart_copy smart_move].each do |mode|
        original = String.new("member")
        set = Set.new([original], mode:, compare_by_identity: true)

        assert_includes set, set.first
        assert_predicate set.first, :frozen?
        refute_includes set, original
      end
    end

    def test_smart_copy_identity_sets_reject_copy_fallbacks
      return unless Internal.native_ractors?
      source = Payload.new(:member)

      assert_raises(ArgumentError) { Set.new([source], mode: :smart_copy, compare_by_identity: true) }
      refute_predicate source, :frozen?
    end

    def test_smart_identity_sets_preserve_local_and_moved_membership
      return unless Internal.native_ractors?
      klass = Class.new(Payload)
      ModeManager::SmartRule.define(klass, :local)
      local = klass.new(:local)
      set = Set.new([local])

      assert_same local, set.first
      assert_includes set, local
      moved = Set.new([Payload.new(:moved)], mode: :smart_move)
      worker = Ractor.new(moved) do |shared|
        value = shared.first
        [value.value, shared.include?(value)]
      end

      assert_equal [:moved, true], ractor_value(worker)
    end

    def test_smart_identity_sets_publish_original_values_across_ractors
      return unless Internal.native_ractors?
      MODES.each do |mode|
        original = Time.now
        set = Set.new([original], mode:, compare_by_identity: true)
        worker = Ractor.new(set) { |shared| shared.include?(shared.first) }

        assert_same original, set.first
        assert_includes set, original
        assert ractor_value(worker)
      end
    end

    def test_lazy_and_lazy_ref_default_to_rejecting_unsupported_results
      lazy = Lazy.new { Payload.new(:unsupported) }
      reference = LazyRef.new { Payload.new(:unsupported) }

      assert_raises(Ractor::IsolationError) { lazy.value }
      assert_raises(Ractor::IsolationError) { reference.value }
    end

    def test_shareable_values_pass_through_every_smart_mode
      MODES.each do |mode|
        manager = ModeManager.new(mode:)

        assert_nil manager.wrap(nil)
        [false, 42, :value, "frozen", [:value].freeze].each do |value|
          assert_same value, manager.wrap(value)
        end
      end
    end

    def test_emulated_ractors_preserve_ordinary_values
      return if Internal.native_ractors?
      MODES.each do |mode|
        manager = ModeManager.new(mode:)
        [String.new("draft"), [], {}, ::Set.new, Time.now].each do |value|
          assert_same value, manager.wrap(value)
          refute_predicate value, :frozen?
        end
      end
    end

    def test_smart_and_smart_raise_reject_values_without_a_rule_or_proxy
      %i[smart smart_raise].each do |mode|
        source = Payload.new(:unsupported)
        assert_raises(Ractor::IsolationError) { ModeManager.new(mode:).wrap(source) }
        assert_equal :unsupported, source.value
      end
    end

    def test_mutable_strings_are_deduplicated_without_freezing_the_source
      return unless Internal.native_ractors?
      MODES.each do |mode|
        manager = ModeManager.new(mode:)
        source = String.new("smart string")
        result = manager.wrap(source)

        assert_equal source, result
        refute_same source, result
        assert_same result, manager.wrap(String.new("smart string"))
        assert Ractor.shareable?(result)
        refute_predicate source, :frozen?
      end
    end

    def test_time_and_date_rules_publish_the_original
      return unless Internal.native_ractors?
      MODES.each do |mode|
        manager = ModeManager.new(mode:)
        [Time.now, Date.today, DateTime.now].each do |value|
          assert_same value, manager.wrap(value)
          assert Ractor.shareable?(value)
        end
      end
    end

    def test_smart_publishes_arrays_and_sets_of_shareable_elements
      return unless Internal.native_ractors?
      [[:value, 42], ::Set[:value, 42]].each do |source|
        assert_same source, ModeManager.new(mode: :smart).wrap(source)
        assert Ractor.shareable?(source)
      end
    end

    def test_symbol_keyed_hashes_with_shareable_values_are_published_in_every_mode
      return unless Internal.native_ractors?
      MODES.each do |mode|
        source = { value: [:ready].freeze }

        assert_same source, ModeManager.new(mode:).wrap(source)
        assert Ractor.shareable?(source)
      end
    end

    def test_ineligible_hashes_use_the_selected_fallback
      return unless Internal.native_ractors?
      %i[smart smart_raise].each do |mode|
        [{ "key" => :value }, { key: [] }].each do |source|
          assert_raises(Ractor::IsolationError) { ModeManager.new(mode:).wrap(source) }
          refute_predicate source, :frozen?
        end
      end
      manager = ModeManager.new(mode: :smart_copy)
      source = { key: [] }
      result = manager.unwrap(manager.wrap(source))
      result[:key] << :receiver

      assert_empty source[:key]
    end

    def test_smart_move_transfers_ineligible_hashes
      return unless Internal.native_ractors?
      skip "CRuby 3.4 corrupts moved hash values" if RUBY_VERSION.start_with?("3.4.")
      moving = ModeManager.new(mode: :smart_move)
      envelope = moving.wrap({ "key" => :value })

      assert_instance_of Envelope::Move, envelope
      assert_equal({ "key" => :value }, moving.unwrap(envelope))
    end

    def test_smart_copy_prepares_flat_containers_without_changing_their_type
      return unless Internal.native_ractors?
      [[:value], ::Set[:value]].each do |source|
        manager = ModeManager.new(mode: :smart_copy)
        result = manager.wrap(source)

        assert_instance_of source.class, result
        refute_same source, result
        assert_equal source, result
        assert Ractor.shareable?(result)
        refute_predicate source, :frozen?
      end
    end

    def test_smart_copy_uses_prepared_strings_without_freezing_original_entries
      return unless Internal.native_ractors?
      entry = String.new("entry")
      source = [entry, entry]
      result = ModeManager.new(mode: :smart_copy).wrap(source)

      assert_equal source, result
      assert_same result[0], result[1]
      refute_same entry, result[0]
      refute_predicate entry, :frozen?
      refute_predicate source, :frozen?
      assert Ractor.shareable?(result)
    end

    def test_smart_copy_falls_back_on_the_original_graph_for_nested_values_and_cycles
      return unless Internal.native_ractors?
      manager = ModeManager.new(mode: :smart_copy)
      entry = []
      source = [entry, entry]
      source << source
      envelope = manager.wrap(source)
      result = manager.unwrap(envelope)

      assert_instance_of Envelope::Copy, envelope
      refute_same source, result
      assert_same result[0], result[1]
      assert_same result, result[2]
      refute_predicate source, :frozen?
      refute_predicate entry, :frozen?
    end

    def test_smart_copy_does_not_put_managed_envelopes_inside_containers
      return unless Internal.native_ractors?
      klass = Class.new(Payload)
      ModeManager::SmartRule.define(klass, :copy)
      manager = ModeManager.new(mode: :smart_copy)
      source = [klass.new(:value)]
      result = manager.unwrap(manager.wrap(source))

      assert_instance_of klass, result.first
      assert_equal :value, result.first.value
      refute_same source.first, result.first
    end

    def test_smart_copy_reconstructs_unshared_containers_when_native_copy_fails
      return unless Internal.native_ractors?
      manager = ModeManager.new(mode: :smart_copy)
      source = Unshared::Map.new({ key: [] })
      envelope = manager.wrap(source)
      result = manager.unwrap(envelope)
      result[:key] << :receiver

      assert_instance_of Envelope::Marshal, envelope
      assert_instance_of Unshared::Map, result
      assert_empty source[:key]
      assert_equal [:receiver], result[:key]
    end

    def test_smart_copy_tries_marshal_after_standard_copy_errors
      [TypeError, ArgumentError, NoMethodError, Ractor::Error, Ractor::IsolationError].each do |error|
        manager = FailingCopyManager.new(error)

        assert_equal :marshaled, manager.wrap(Payload.new(:value))
        assert_equal %i[copy marshal], manager.attempts.to_a
      end
    end

    def test_smart_copy_preserves_the_copy_error_when_marshal_also_fails
      manager = FailingCopyManager.new(ArgumentError, marshal_failure: true)
      error = assert_raises(ArgumentError) { manager.wrap(Payload.new(:value)) }

      assert_equal "copy failed", error.message
      assert_equal %i[copy marshal], manager.attempts.to_a
    end

    def test_smart_move_transfers_unsupported_values
      manager = ModeManager.new(mode: :smart_move)
      envelope = manager.wrap(Payload.new(:value))
      worker = Ractor.new(manager, envelope) { |shared, message| shared.unwrap(message).value }

      assert_instance_of Envelope::Move, envelope
      assert_equal :value, ractor_value(worker)
    end

    def test_fixed_rules_apply_to_subclasses_and_every_smart_mode
      klass = Class.new(Payload)
      child = Class.new(klass)
      ModeManager::SmartRule.define(klass, :local)
      MODES.each do |mode|
        manager = ModeManager.new(mode:)
        source = child.new(:value)

        assert_same source, manager.unwrap(manager.wrap(source))
      end
    end

    def test_callable_rules_receive_the_value_manager_and_selected_mode
      klass = Class.new(Payload)
      ModeManager::SmartRule.define(klass) do |value, manager, mode|
        manager.wrap([value.value, mode], mode: :make_shareable)
      end

      MODES.each do |mode|
        assert_equal [:value, mode], ModeManager.new(mode:).wrap(klass.new(:value))
      end
    end

    def test_method_rules_are_private_and_smart_dispatches_to_smart_raise
      klass = Class.new(Payload)
      rule = ModeManager::SmartRule.define(klass) do
        define_method(:smart_raise) { |value, _| [value.value, :raise].freeze }
        define_method(:smart_copy) { |value, _| [value.value, :copy].freeze }
        define_method(:smart_move) { |value, _| [value.value, :move].freeze }
      end

      { smart: :raise, smart_raise: :raise, smart_copy: :copy, smart_move: :move }.each do |mode, tag|
        assert_equal [:value, tag], ModeManager.new(mode:).wrap(klass.new(:value))
      end
      %i[smart_raise smart_copy smart_move].each { |method| assert rule.private_method_defined?(method) }
    end

    def test_late_rule_definitions_invalidate_existing_subclass_lookups
      klass = Class.new(Payload)
      child = Class.new(klass)
      source = child.new(:value)
      manager = ModeManager.new(mode: :smart)

      assert_raises(Ractor::IsolationError) { manager.wrap(source) }
      ModeManager::SmartRule.define(klass, :local)

      assert_same source, manager.unwrap(manager.wrap(source))
    end

    def test_dedicated_proxies_are_used_in_every_smart_mode
      register = Proxy::Register.new
      register.define(Payload) { define_method(:value) { super() } }
      MODES.each do |mode|
        manager = ModeManager.new(mode:, register:)
        proxy = manager.wrap(Payload.new(:value))
        @proxies << proxy

        assert_operator Proxy, :===, proxy
        assert_equal :value, proxy.value
      end
    end

    def test_callable_rules_work_in_another_ractor
      klass = Class.new(Payload)
      ModeManager::SmartRule.define(klass) do |value, manager, _|
        manager.wrap([value.value], mode: :make_shareable)
      end
      manager = ModeManager.new(mode: :smart)
      worker = Ractor.new(manager, klass) { |shared, type| shared.wrap(type.new(:value)) }

      assert_equal [:value], ractor_value(worker)
    end
  end
end
