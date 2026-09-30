# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMolecule < Test
    include Helpers::InternalTestHelpers

    VARIANTS = [Molecule, Strict::Molecule, Local::Molecule, Unshared::Molecule].freeze
    SHARED = [Molecule, Strict::Molecule, Local::Molecule].freeze

    def test_definition_metadata_and_inheritance
      VARIANTS.each do |variant|
        klass = variant.define("name", :count)
        child = Class.new(klass)

        assert_equal %i[name count], klass.members
        assert_equal %i[name_atom count_atom], klass.atoms
        assert_predicate klass.members, :frozen?
        assert_predicate klass.atoms, :frozen?
        assert_same klass.members, child.members
        assert_same klass.atoms, child.atoms
        refute_respond_to klass, :define
        assert_equal({ name: :job, count: 1 }, child.new(:job, count: 1).to_h)
      end
    end

    def test_initialization_and_atomic_field_access
      VARIANTS.each do |variant|
        record = variant.define(:name, :count, :missing).new(:job, count: 1)

        assert_equal :job, record.name
        assert_nil record.missing
        assert_kind_of Abstract::Atom, record.count_atom
        assert_equal(2, record.count_atom.update { |value| value + 1 })
        record.name = :done

        assert_equal :done, record.name
        assert record.count_atom.compare_and_set(2, 3)
        assert_equal 3, record.count
        assert_kind_of Abstract::Molecule, record
      end
    end

    def test_enumeration
      record = Molecule.define(:name, :count).new(:job, 1)

      assert_equal [%i[name job], [:count, 1]], record.each.to_a
      assert_equal record.each.to_a, record.each_pair.to_a
      assert_equal %i[name count], record.each_member.to_a
      assert_equal record.members, record.each_key.to_a
      assert_equal [:job, 1], record.each_value.to_a
      assert_equal [[:name_atom, record.name_atom], [:count_atom, record.count_atom]], record.each_atom.to_a
      %i[each each_pair each_member each_key each_value each_atom].each do |method|
        seen = []
        record.public_send(method) { |*values| seen << values }

        refute_empty seen
      end
    end

    def test_empty_records
      assert_empty Abstract::Molecule.members
      assert_empty Abstract::Molecule.atoms
      VARIANTS.each do |variant|
        record = variant.define.new

        assert_empty record.to_h
        assert_empty record.each_atom.to_a
      end
    end

    def test_invalid_initial_values
      VARIANTS.each do |variant|
        klass = variant.define(:name)
        assert_raises(ArgumentError) { klass.new(1, 2) }
        assert_raises(ArgumentError) { klass.new(1, name: 2) }
        assert_raises(ArgumentError) { klass.new(unknown: 2) }
      end
    end

    def test_invalid_field_names
      VARIANTS.each do |variant|
        [[:name, "name"], %i[name name_atom], %i[name name=], [:members], [:each],
         [:initialize], [:freeze], [:compare_by_identity]].each do |fields|
          assert_raises(ArgumentError) { variant.define(*fields) }
        end
      end
      assert_raises(ArgumentError) { Molecule.define(:mode) }
      assert_raises(ArgumentError) { Local::Molecule.define(:scope) }
    end

    def test_unusual_names_and_uppercase_names
      VARIANTS.each do |variant|
        record = variant.define(:"job-name", :Title).new(:first, :second)

        assert_equal :first, record.public_send(:"job-name")
        assert_equal :second, record.Title
        record.public_send(:"job-name=", :changed)
        record.Title = :updated

        assert_equal({ "job-name": :changed, Title: :updated }, record.to_h)
        assert_equal :changed, record.public_send(:"job-name_atom").value
      end
    end

    def test_existing_atoms_keep_their_identity_and_policy
      VARIANTS.each do |variant|
        atom = Strict::Atom.new(1, compare_by_identity: true)
        record = variant.define(:count).new(atom)

        assert_same atom, record.count_atom
        record.count = 2

        assert_equal 2, atom.value
        assert_predicate record.count_atom, :compare_by_identity?
      end
    end

    def test_abstract_atom_factory
      klass = Abstract::Molecule.define(:name)
      assert_raises(NoMethodError) { klass.new(:job) }
      child = Class.new(klass) do
        private def create_atom(_, value) = Strict::Atom.new(value)
      end

      assert_equal :job, child.new(:job).name
    end

    def test_subclasses_can_supply_an_atom_without_a_generated_writer
      klass = Class.new(Abstract::Molecule.define(:name)) do
        undef_method :name_atom=

        def initialize(*)
          @name_atom = Strict::Atom.new(:initial)
          super
        end
      end

      assert_equal :initial, klass.new.name
      assert_equal :replacement, klass.new(:replacement).name
      invalid = Class.new(klass) do
        def name_atom = :not_an_atom
      end
      assert_raises(TypeError) { invalid.new(:replacement) }
    end

    def test_comparison_defaults_and_overrides_for_all_variants
      VARIANTS.each do |variant|
        refute_predicate variant, :compare_by_identity?
        default = variant.define(:item).new(:initial)

        refute_predicate default, :compare_by_identity?
        refute_predicate default.item_atom, :compare_by_identity?

        klass = variant.define(:item, compare_by_identity: true)
        child = Class.new(klass)

        assert_predicate klass, :compare_by_identity?
        assert_predicate child, :compare_by_identity?
        [klass.new(:initial), child.new(:initial, compare_by_identity: nil)].each do |record|
          assert_predicate record, :compare_by_identity?
          assert_predicate record.item_atom, :compare_by_identity?
        end
        overridden = child.new(:initial, compare_by_identity: false)

        refute_predicate overridden, :compare_by_identity?
        refute_predicate overridden.item_atom, :compare_by_identity?
        assert_predicate child, :compare_by_identity?
      end
    end

    def test_mode_and_comparison_defaults_and_overrides
      klass = Molecule.define(:items, mode: :local, compare_by_identity: true)
      items = []
      record = klass.new(items)

      assert_equal :local, record.mode
      assert_same items, record.items
      assert_predicate record, :compare_by_identity?
      assert_predicate record.items_atom, :compare_by_identity?
      assert_equal :local, record.items_atom.mode

      other = klass.new([], mode: :make_shareable, compare_by_identity: false)

      assert_equal :make_shareable, other.mode
      refute_predicate other, :compare_by_identity?
      assert Ractor.shareable?(other.items)
      assert_equal :copy, Molecule.define(:item).new.item_atom.mode
      assert_raises(ArgumentError) { klass.new(mode: :invalid) }
    end

    def test_freeze_prevents_field_and_atom_updates
      SHARED.each do |variant|
        record = variant.define(:count).new(1)

        refute_predicate record, :frozen?
        assert_same record, record.freeze
        assert_same record, record.freeze
        assert_predicate record, :frozen?
        assert_predicate record.count_atom, :frozen?
        assert_raises(FrozenError) { record.count = 2 }
        assert_raises(FrozenError) { record.count_atom.update { 2 } }
        assert_equal 1, record.count
      end
    end

    def test_freeze_does_not_freeze_stored_values
      value = []
      record = Molecule.define(:items, mode: :local).new(value)
      record.freeze

      refute_predicate value, :frozen?
      assert_same value, record.items
    end

    def test_strict_values_must_be_shareable
      klass = Strict::Molecule.define(:items)
      rejected = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) { klass.new(rejected) }
      assert_raises(Ractor::IsolationError) { klass.new([]) } if Internal.native_ractors?
      record = klass.new([].freeze)
      assert_raises(Ractor::IsolationError) { record.items = rejected }
      assert_raises(Ractor::IsolationError) { record.items_atom.update { rejected } }
      assert_empty record.items
    end

    def test_local_definition_scope_defaults_and_overrides
      assert_equal :ractor, Local::Molecule.default_scope
      assert_equal :ractor, Local::Molecule.define(:count).new.scope
      klass = Local::Molecule.define(:count, scope: :thread, compare_by_identity: true)
      child = Class.new(klass)
      record = child.new(1)

      assert_equal :thread, klass.default_scope
      assert_equal :thread, child.default_scope
      assert_equal :thread, record.scope
      assert_equal :thread, record.count_atom.scope
      assert_predicate record.count_atom, :compare_by_identity?
      record.count = 2

      assert_equal 1, Thread.new { record.count }.value
      assert_equal 2, record.count
      overridden = child.new(1, scope: :fiber)
      overridden.count = 3

      assert_equal :fiber, overridden.scope
      assert_equal :fiber, overridden.count_atom.scope
      assert_equal 1, Fiber.new { overridden.count }.resume
      assert_equal 3, overridden.count
      assert_equal :thread, child.default_scope
      assert_raises(ArgumentError) { Local::Molecule.define(:count, scope: :invalid) }
    end

    def test_local_fields_select_the_current_scope
      klass = Local::Molecule.define(:count)
      record = klass.new(1, scope: :thread, compare_by_identity: true)

      assert_equal :thread, record.scope
      assert_equal :thread, record.count_atom.scope
      assert_predicate record.count_atom, :compare_by_identity?
      record.count = 2

      assert_equal [1, 3], Thread.new { [record.count, record.count_atom.update { 3 }] }.value
      assert_equal 2, record.count
      assert_raises(ArgumentError) { klass.new(scope: :invalid) }
    end

    def test_freezing_local_fields_applies_to_new_scopes
      record = Local::Molecule.define(:count).new(1, scope: :fiber)
      record.freeze
      error = Fiber.new do
        assert_equal 1, record.count
        assert_raises(FrozenError) { record.count = 2 }
      end.resume

      assert_kind_of FrozenError, error
    end

    def test_unshared_fields_retain_mutable_values
      value = []
      record = Unshared::Molecule.define(:items).new(value)

      assert_same value, record.items
      assert_instance_of Unshared::Atom, record.items_atom
      refute_predicate record, :ractor_shareable?
      refute_respond_to record, :freeze
    end

    def test_fields_accept_basic_objects
      value = BasicObject.new
      record = Unshared::Molecule.define(:item).new(value)

      assert_same value, record.item
    end

    def test_atomic_updates_from_threads
      VARIANTS.each do |variant|
        record = variant.define(:count).new(0)
        threads = 4.times.map { Thread.new { 50.times { record.count_atom.update { it + 1 } } } }
        threads.each(&:value)

        assert_equal 200, record.count
      end
    end

    def test_shared_records_work_across_ractors
      [Molecule, Strict::Molecule].each do |variant|
        record = variant.define(:count, :"job-name").new(1, :pending)

        assert Ractor.shareable?(record)
        worker = Ractor.new(record) do |shared|
          shared.public_send(:"job-name=", :done)
          shared.count_atom.update { it + 1 }
        end

        assert_equal 2, ractor_value(worker)
        assert_equal 2, record.count
        assert_equal :done, record.public_send(:"job-name")
      end
    end

    def test_local_records_have_independent_values_in_other_ractors
      record = Local::Molecule.define(:count).new(1)
      record.count = 2

      assert Ractor.shareable?(record)
      worker = Ractor.new(record) do |local|
        [local.count, local.count_atom.update { it + 2 }]
      end

      assert_equal [1, 3], ractor_value(worker)
      assert_equal 2, record.count
    end
  end
end
