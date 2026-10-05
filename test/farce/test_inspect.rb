# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestInspect < Test
    include Helpers::InternalTestHelpers

    NAMESPACES = [Farce, Strict, Unshared, Local, Unsafe].freeze
    MAP_NAMES = %i[Map TreeMap LRUMap LFUMap WeakMap WeakKeyMap WeakValueMap].freeze

    class BrokenFormatting
      def inspect = raise("inspect failed")
      def pretty_print(_) = raise("pretty_print failed")
    end

    def test_atoms_show_their_current_value_and_transfer_mode
      variants(:Atom).each do |klass|
        atom = klass.new(:initial)
        mode = klass == Atom ? " mode=:copy" : ""

        assert_inspection "#<#{klass.name}#{mode} value=:initial>", atom
        atom.value = nil

        assert_inspection "#<#{klass.name}#{mode} value=nil>", atom
      end
    end

    def test_weak_atoms_show_live_and_nil_values
      variants(:WeakAtom).each do |klass|
        atom = klass.new(:initial)

        assert_inspection "#<#{klass.name} value=:initial>", atom
        atom.value = nil

        assert_inspection "#<#{klass.name} value=nil>", atom
      end
    end

    def test_counters_and_flags_show_updates
      variants(:Counter).each do |klass|
        counter = klass.new(2)

        assert_inspection "#<#{klass.name} 2>", counter
        counter.increment

        assert_inspection "#<#{klass.name} 3>", counter
      end
      variants(:Flag).each do |klass|
        flag = klass.new

        assert_inspection "#<#{klass.name} false>", flag
        flag.set

        assert_inspection "#<#{klass.name} true>", flag
      end
    end

    def test_exchangers_show_only_their_identity
      variants(:Exchanger).each do |klass|
        exchanger = klass.new
        expected = /\A#<#{Regexp.escape(klass.name)}:0x[0-9a-f]+>\z/

        assert_match expected, exchanger.inspect
        assert_equal "#{exchanger.inspect}\n", PP.pp(exchanger, +"")
      end
    end

    def test_queue_families_show_size_capacity_and_closed_state
      %i[Queue PriorityQueue TimerQueue].each do |name|
        variants(name).each do |klass|
          queue = klass.new(capacity: 2)

          assert_inspection "#<#{klass.name} size=0 capacity=2>", queue
          queue.push(:item)

          assert_inspection "#<#{klass.name} size=1 capacity=2>", queue
          queue.close

          assert_inspection "#<#{klass.name} closed>", queue
          assert_equal 1, queue.size
        end
      end
    end

    def test_unbounded_queues_omit_capacity
      variants(:Queue).each do |klass|
        assert_inspection "#<#{klass.name} size=0>", klass.new(capacity: nil)
      end
    end

    def test_maps_show_empty_and_populated_entries
      MAP_NAMES.each do |name|
        variants(name).each do |klass|
          options = %i[LRUMap LFUMap].include?(name) ? { max_size: 2 } : {}

          assert_inspection "#<#{klass.name} {}>", klass.new(**options)
          assert_inspection "#<#{klass.name} {key: :value}>", klass.new({ key: :value }, **options)
        end
      end
    end

    def test_maps_format_symbol_and_non_symbol_keys
      { :key => "key:", :"with space" => '"with space":', 1 => "1 =>" }.each do |key, label|
        map = Unshared::Map.new({ key => :value })

        assert_inspection "#<Farce::Unshared::Map {#{label} :value}>", map
      end
    end

    def test_mode_maps_show_nil_instead_of_the_storage_placeholder
      [Map, WeakKeyMap, WeakValueMap, WeakMap].each do |klass|
        map = klass.new({ key: nil })

        assert_inspection "#<#{klass.name} {key: nil}>", map
        assert_nil map[:key]
      end
    end

    def test_move_maps_do_not_claim_values_during_inspection
      return unless Internal.native_ractors?

      [Map, WeakKeyMap].each { assert_move_map_inspection(it) }
    end

    def test_move_tree_maps_do_not_claim_values_during_inspection
      return unless Internal.native_ractors?

      assert_move_map_inspection TreeMap
    end

    def test_move_lru_maps_do_not_claim_values_during_inspection
      return unless Internal.native_ractors?

      assert_move_map_inspection LRUMap, max_size: 2
    end

    def test_move_lfu_maps_do_not_claim_values_during_inspection
      return unless Internal.native_ractors?

      assert_move_map_inspection LFUMap, max_size: 2
    end

    def test_move_atoms_do_not_claim_values_during_inspection
      return unless Internal.native_ractors?

      %i[inspect pretty_inspect].each do |method|
        atom = Atom.new(ModePayload.new(:value), mode: :move)

        assert_equal "#<Farce::Atom mode=:move unclaimed>", atom.public_send(method).chomp
        worker = Ractor.new(atom) { |shared| shared.value.value }

        assert_equal :value, ractor_value(worker)
        assert_inspection "#<Farce::Atom mode=:move claimed>", atom
      end
    end

    def test_explicit_move_envelopes_remain_wrapped_and_unclaimed
      return unless Internal.native_ractors?

      envelope = Envelope::Move.new(ModePayload.new(:value))
      map = Map.new({ key: envelope })

      assert_inspection "#<Farce::Map {key: #<Farce::Envelope::Move unclaimed>}>", map
      refute_predicate envelope, :claimed?
      worker = Ractor.new(envelope) { |shared| shared.value.value }

      assert_equal :value, ractor_value(worker)
    end

    def test_lazy_inspection_does_not_call_the_factory
      variants(:Lazy).each do |klass|
        calls = Counter.new
        lazy = klass.new do
          calls.increment
          :value
        end

        assert_match(/\A#<#{Regexp.escape(klass.name)} #<Proc:/, lazy.inspect)
        PP.pp(lazy, +"")

        assert_equal 0, calls.value

        assert_equal :value, lazy.value
        assert_inspection "#<#{klass.name} :value>", lazy
        assert_equal 1, calls.value
      end
    end

    def test_lazy_inspection_distinguishes_resolved_nil_and_false_from_the_factory
      variants(:Lazy).each do |klass|
        [nil, false].each do |result|
          lazy = klass.new { result }
          lazy.value

          assert_inspection "#<#{klass.name} #{result.inspect}>", lazy
        end
      end
    end

    def test_inspecting_a_published_lazy_move_result_leaves_it_available
      return unless Internal.native_ractors?

      %i[inspect pretty_inspect].each do |method|
        lazy = Lazy.new(mode: :move) { ModePayload.new(:value) }
        # Publish the result without the public Lazy#value method opening it.
        envelope = Abstract::Lazy.instance_method(:value).bind_call(lazy)

        refute_predicate envelope, :claimed?
        assert_equal "#<Farce::Lazy unclaimed>", lazy.public_send(method).chomp
        refute_predicate envelope, :claimed?
        worker = Ractor.new(lazy) { |shared| shared.value.value }

        assert_equal :value, ractor_value(worker)
        assert_inspection "#<Farce::Lazy claimed>", lazy
      end
    end

    def test_leases_show_state_without_acquiring_or_printing_resources
      variants(:Lease).each do |klass|
        lease = klass.new { :resource }

        assert_inspection "#<#{klass.name} available>", lease
        assert_predicate lease, :available?
        lease.checkout do
          assert_inspection "#<#{klass.name} checked_out>", lease
          assert_predicate lease, :owned?
        end
        assert_inspection "#<#{klass.name} available>", lease
        lease.checkout { lease.retire }

        assert_inspection "#<#{klass.name} retired>", lease
      end
    end

    def test_lease_pools_show_size_without_creating_or_acquiring_resources
      variants(:LeasePool).each do |klass|
        calls = Counter.new
        pool = klass.new(max_size: 2) do
          calls.increment
          :resource
        end

        assert_inspection "#<#{klass.name} size=0 max_size=2>", pool
        assert_equal 0, calls.value
        pool.checkout do
          assert_inspection "#<#{klass.name} size=1 max_size=2>", pool
          assert_equal 1, pool.checked_out_count
        end
        assert_inspection "#<#{klass.name} size=1 max_size=2>", pool
        assert_equal 1, pool.available_count
        assert_equal 1, calls.value
      end
    end

    def test_lease_maps_show_states_without_checking_out_resources
      variants(:LeaseMap).each do |klass|
        map = klass.new { { key: :resource } }

        assert_inspection "#<#{klass.name} {key: available}>", map
        assert map.available?(:key)
        map.checkout(:key) do
          assert_inspection "#<#{klass.name} {key: owned}>", map
          assert map.owned?(:key)
          map.lease_for(:key).retire

          assert_inspection "#<#{klass.name} {}>", map
        end
      end
    end

    def test_molecules_show_fields_in_declaration_order
      variants(:Molecule).each do |variant|
        klass = variant.define(:name, :count, :missing)
        record = klass.new(:job, 2)

        assert_inspection "#<#{klass.name} name=:job count=2 missing=nil>", record
        record.count = 3

        assert_inspection "#<#{klass.name} name=:job count=3 missing=nil>", record
      end
    end

    def test_molecule_inspection_does_not_claim_field_values
      return unless Internal.native_ractors?

      record = Molecule.define(:item).new(ModePayload.new(:value), mode: :move)

      assert_inspection "#<#{record.class.name} item=unclaimed>", record
      worker = Ractor.new(record) { |shared| shared.item.value }

      assert_equal :value, ractor_value(worker)
      assert_inspection "#<#{record.class.name} item=claimed>", record
    end

    def test_empty_molecules_show_their_generated_class_name
      variants(:Molecule).each do |variant|
        klass = variant.define

        assert_inspection "#<#{klass.name}>", klass.new
      end
    end

    def test_envelopes_show_accessible_values
      [
        Envelope::Share.new(:value),
        Envelope::Local.new(:value),
        Envelope::Copy.new(ModePayload.new(:value))
      ].each do |envelope|
        assert_inspection "#<#{envelope.class.name} value=#{envelope.value.inspect}>", envelope
      end
    end

    def test_weak_values_show_the_value_without_unwrapping_envelopes
      [nil, false, :value].each do |value|
        assert_inspection "#<Farce::WeakValue state=:alive value=#{value.inspect}>", WeakValue.new(value)
      end
      return unless Internal.native_ractors?

      envelope = Envelope::Move.new(ModePayload.new(:value))
      weak = WeakValue.new(envelope)

      assert_inspection "#<Farce::WeakValue state=:alive value=#<Farce::Envelope::Move unclaimed>>", weak
      refute_predicate envelope, :claimed?
    end

    def test_recursive_atoms_maps_and_lazy_values_use_identity_placeholders
      atom = Unshared::Atom.new
      atom.value = atom
      map = Unshared::Map.new
      map[:self] = map
      lazy = nil
      lazy = Unshared::Lazy.new { lazy }
      lazy.value

      [atom, map, lazy].each do |object|
        address = Kernel.instance_method(:to_s).bind_call(object)

        assert_includes object.inspect, address
        assert_includes PP.pp(object, +""), address
      end
    end

    def test_foreign_formatting_errors_fall_back_to_object_identity
      value = BrokenFormatting.new
      atom = Unshared::Atom.new(value)
      expected = "#<Farce::Unshared::Atom value=#{Kernel.instance_method(:to_s).bind_call(value)}>"

      assert_inspection expected, atom
    end

    def test_foreign_containers_format_nested_farce_values
      atom = Unshared::Atom.new([Counter.new(2)])

      assert_inspection "#<Farce::Unshared::Atom value=[#<Farce::Counter 2>]>", atom
    end

    def test_foreign_containers_preserve_recursion_protection
      atom = Unshared::Atom.new
      atom.value = [atom]
      address = Kernel.instance_method(:to_s).bind_call(atom)

      assert_equal "#<Farce::Unshared::Atom value=[#{address}]>", atom.inspect
      assert_includes PP.pp(atom, +""), address.delete_suffix(">")
    end

    def test_foreign_containers_keep_nested_output_separate
      atom = Unshared::Atom.new([Counter.new(2), { count: Counter.new(3) }])

      assert_inspection "#<Farce::Unshared::Atom value=[#<Farce::Counter 2>, {count: #<Farce::Counter 3>}]>", atom
    end

    def test_transaction_inspection_rejects_closed_attempts
      [Atom.new, Map.new, TreeMap.new, Molecule.define.new].each do |object|
        wrapped = nil

        assert Transaction.run(object) { |_, value| wrapped = value }
        assert_raises(Transaction::ClosedError) { wrapped.inspect }
        assert_raises(Transaction::ClosedError) { PP.pp(wrapped, +"") }
        assert_raises(Transaction::ClosedError) { wrapped.inspect_with(nil) }
      end
    end

    def test_transaction_inspection_rejects_other_fibers
      [Atom.new, Map.new, TreeMap.new, Molecule.define.new].each do |object|
        assert Transaction.run(object) { |_, wrapped|
          %i[inspect pretty_inspect].each do |method|
            error = Fiber.new do
              wrapped.public_send(method)
            rescue StandardError => e
              e
            end.resume

            assert_instance_of Transaction::OwnershipError, error
          end
        }
      end
    end

    def test_transaction_atoms_show_staged_values
      atom = Atom.new(:initial)

      assert Transaction.run(atom) { |_, wrapped|
        wrapped.value = :staged

        assert_inspection "#<Farce::Transaction::Atom value=:staged>", wrapped
      }
      assert_equal :staged, atom.value
    end

    def test_transaction_maps_show_staged_values
      map = Map.new({ key: :initial })

      assert Transaction.run(map) { |_, wrapped|
        wrapped[:key] = :staged

        assert_inspection "#<Farce::Transaction::Map {key: :staged}>", wrapped
      }
      assert_equal :staged, map[:key]
    end

    def test_transaction_tree_maps_show_staged_values
      map = TreeMap.new({ 1 => :initial })

      assert Transaction.run(map) { |_, wrapped|
        wrapped[1] = :staged

        assert_inspection "#<Farce::Transaction::TreeMap {1 => :staged}>", wrapped
      }
      assert_equal :staged, map[1]
    end

    def test_transaction_molecules_show_staged_values
      record = Molecule.define(:item).new(:initial)

      assert Transaction.run(record) { |_, wrapped|
        wrapped.item = :staged

        assert_inspection "#<Farce::Transaction::Molecule item=:staged>", wrapped
      }
      assert_equal :staged, record.item
    end

    def test_pretty_print_wraps_nested_contents
      map = Map.new({ key: %i[first second third] })

      assert_equal "#<Farce::Map {key: [:first, :second, :third]}>", map.inspect
      output = PP.pp(map, +"", 30)

      assert_operator output.lines.size, :>, 1
      assert_includes output, "key:"
      %w[first second third].each { assert_includes output, ":#{it}" }
    end

    private

    def variants(name)
      NAMESPACES.filter_map do |namespace|
        namespace.const_get(name, false) if namespace.const_defined?(name, false)
      end.uniq
    end

    def assert_move_map_inspection(klass, **)
      %i[inspect pretty_inspect].each do |method|
        map = klass.new({ key: ModePayload.new(:value) }, mode: :move, **)

        assert_equal "#<#{klass.name} {key: unclaimed}>", map.public_send(method).chomp
        worker = Ractor.new(map) { |shared| shared[:key].value }

        assert_equal :value, ractor_value(worker)
        assert_inspection "#<#{klass.name} {key: claimed}>", map
      end
    end

    def assert_inspection(expected, object)
      assert_equal expected, object.inspect
      assert_equal "#{expected}\n", PP.pp(object, +"", 200)
    end
  end
end
