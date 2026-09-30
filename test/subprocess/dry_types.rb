# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/dry_types"
require "shellwords"

module Farce
  class DryTypesIntegrationTests < Test
    module Types
      include ::Dry.Types()
      include Farce.DryTypes()
    end

    def test_vector_coercion_composition_and_failures
      type = Types::Vector.of(Types::Coercible::Integer)
      input = ["1", 2]
      vector = type[input]

      assert_instance_of Vector, vector
      assert_equal :copy, vector.mode
      assert_equal [1, 2], vector.to_a
      assert_equal ["1", 2], input
      assert_instance_of Vector, type.optional[["3"]]
      assert_nil type.optional[nil]

      failure = type.try(["bad"])

      assert_predicate failure, :failure?
      assert_equal ["bad"], failure.input
      fallback = type.call(["bad"]) { |partial| [:invalid, partial] }

      assert_equal :invalid, fallback.first
      refute_instance_of Vector, fallback.last
      assert_raises(::Dry::Types::CoercionError) { type[["bad"]] }
    end

    def test_typed_default_is_explicitly_constructed
      type = Types::Vector.of(Types::Coercible::Integer)
      with_default = type.default { type[["4"]] }
      first = with_default[]
      second = with_default[]

      assert_instance_of Vector, first
      assert_equal [4], first.to_a
      refute_same first, second
    end

    def test_outer_constraints_fallbacks_and_nested_array_composition
      member_type = Types::Vector.of(Types::Coercible::Integer)
      constrained = member_type.constrained(min_size: 2)

      assert_equal [1, 2], constrained[["1", 2]].to_a
      assert_predicate constrained.try([1]), :failure?
      fallback = constrained.fallback { Types::Vector[[0, 0]] }

      assert_equal [0, 0], fallback[[1]].to_a

      nested = ::Dry::Types["array"].of(member_type)
      vectors = nested[[["3"], [4]]]

      assert_equal [[3], [4]], vectors.map(&:to_a)
      vectors.each { assert_instance_of Vector, it }
    end

    def test_homogeneous_map_and_duplicate_coerced_keys
      type = Types::Map.map(Types::Coercible::Integer, Types::Coercible::String)
      map = type["1" => :one, 2 => "two"]

      assert_instance_of Map, map
      assert_equal :copy, map.mode
      assert_equal({ 1 => "one", 2 => "two" }, map.to_h)

      collision = type.try("1" => "first", 1 => "second")

      assert_predicate collision, :failure?
      assert_includes collision.error.message, "duplicate coerced hash key 1"
      assert_equal :invalid, type.call("bad") { :invalid }
      assert_raises(::Dry::Types::CoercionError) { type["bad"] }
    end

    def test_hash_schema_and_nested_vector_composition
      scores = Types::Vector.of(Types::Coercible::Integer)
      type = Types::Map.schema(name: Types::String, scores:).strict
      map = type[name: "Ada", scores: ["1", 2]]

      assert_instance_of Map, map
      assert_equal "Ada", map[:name]
      assert_instance_of Vector, map[:scores]
      assert_equal [1, 2], map[:scores].to_a

      unknown = type.try(name: "Ada", scores: [], extra: true)

      assert_predicate unknown, :failure?
      assert_raises(NoMethodError) do
        Types::Vector.of(Types::String).schema(name: Types::String)
      end

      transformed = Types::Map.schema(scores:).strict.with_key_transform(&:to_sym)
      transformed_map = transformed["scores" => ["3"]]

      assert_equal [3], transformed_map[:scores].to_a
    end

    def test_set_coerces_before_deduplicating
      type = Types::Set.of(Types::Coercible::Integer)
      set = type[["1", 1, "2"]]

      assert_instance_of Set, set
      assert_equal :copy, set.mode
      assert_equal [1, 2], set.to_a.sort
      assert_equal [3, 4], type[::Set["3", "4"]].to_a.sort
      assert_predicate type.try(["bad"]), :failure?
      assert_equal({ any: 1 }, Types::Map[{ any: 1 }].to_h)
      assert_equal [1], Types::Set[[1]].to_a

      constrained = type.constrained(min_size: 2)

      assert_predicate constrained.try(["1", 1]), :failure?
    end

    def test_dry_import_settings_namespaces_and_aliases
      assert_predicate Types::Vector.try("1"), :failure?
      assert_equal ["1"], Types::Coercible::Vector["1"].to_a

      inherited = Module.new do
        include ::Dry.Types(default: :coercible)
        include Farce.DryTypes(variant: :local, scope: :thread)
      end
      overridden = Module.new do
        include ::Dry.Types(default: :coercible)
        include Farce.DryTypes(default: :strict)
      end
      checked = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(strict: :Checked)
      end

      assert_equal ["1"], inherited::Vector["1"].to_a
      assert_instance_of Local::Vector, inherited::Vector[[]]
      assert_predicate overridden::Vector.try("1"), :failure?
      assert_equal [1], checked::Checked::Vector.of(checked::Integer)[[1]].to_a
      refute checked.const_defined?(:Vector, false)
    end

    def test_optional_collection_types_preserve_nil
      optional = Module.new do
        include ::Dry.Types(default: :optional)
        include Farce.DryTypes()
      end

      vector = optional::Vector.of(Types::Coercible::Integer)
      map = optional::Map.map(Types::Coercible::Integer, Types::String)

      assert_nil vector[nil]
      assert_nil map[nil]
      assert_equal [1], vector[["1"]].to_a
      assert_equal({ 1 => "one" }, map["1" => "one"].to_h)
    end

    def test_variants_do_not_mutate_reused_dry_import
      dry = ::Dry.Types()
      local = Module.new do
        include dry
        include Farce.DryTypes(variant: :local, scope: :thread)
      end
      unshared = Module.new do
        include dry
        include Farce.DryTypes(variant: :unshared)
      end

      local_vector = local::Vector[[1]]

      assert_instance_of Local::Vector, local_vector
      assert_equal :thread, local_vector.scope
      assert_instance_of Unshared::Vector, unshared::Vector[[1]]
      refute dry.const_defined?(:Vector, false)
      refute dry::Coercible.const_defined?(:Vector, false)
    end

    def test_strict_variant_and_factory_shared_mode
      strict = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(variant: :strict)
      end
      local_values = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(mode: :local)
      end
      value = []

      assert_instance_of Strict::Vector, strict::Vector[[1]]
      assert_same value, local_values::Vector[[value]][0]
    end

    def test_explicit_selection_preserves_existing_namespace_constants
      types = Module.new { include ::Dry.Types() }
      types::Coercible.const_set(:Token, types::String)
      types.include Farce.DryTypes(default: :coercible)

      assert_same types::String, types::Coercible::Token
      assert_instance_of Vector, types::Vector[[1]]
      assert_raises(ArgumentError) { Farce.DryTypes(variant: :local, scope: :unknown) }
      assert_raises(ArgumentError) { Farce.DryTypes(variant: :strict, mode: :copy) }
    end

    def test_identity_hash_does_not_silently_drop_structural_duplicates
      first = +"key"
      second = +"key"
      input = {}.compare_by_identity
      input[first] = 1
      input[second] = 2

      failure = Types::Map.try(input)

      assert_predicate failure, :failure?
      assert_includes failure.error.message, "duplicate structural hash key"
      assert_equal 2, input.size
    end

    def test_counter_and_flag_use_imported_scalar_types
      counter = Types::Counter[2]
      coerced = Types::Coercible::Counter["3"]
      flag = Types::Params::Flag["yes"]

      assert_instance_of Counter, counter
      assert_equal 2, counter.value
      assert_instance_of Counter, coerced
      assert_equal 3, coerced.value
      assert_instance_of Flag, flag
      assert flag.value
      assert_predicate Types::Counter.try("3"), :failure?
      assert_predicate Types::Flag.try("true"), :failure?
      refute Types::Coercible.const_defined?(:Flag, false)
    end

    def test_scalar_types_follow_default_and_alias_selection
      params = Module.new do
        include ::Dry.Types(default: :params)
        include Farce.DryTypes()
      end
      optional = Module.new do
        include ::Dry.Types(default: :optional)
        include Farce.DryTypes()
      end
      checked = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(strict: :Checked)
      end

      assert_equal 4, params::Counter["4"].value
      refute params::Flag["no"].value
      assert_nil optional::Counter[nil]
      assert_equal 5, optional::Counter[5].value
      refute optional.const_defined?(:Flag, false)
      assert_equal 6, checked::Checked::Counter[6].value
      assert_equal "value", checked::Checked::Atom["value"].value
    end

    def test_atom_validates_only_its_initial_value
      type = Types::Atom.of(Types::Coercible::Integer)
      atom = type["7"]

      assert_instance_of Atom, atom
      assert_equal 7, atom.value
      atom.value = "later"

      assert_equal "later", atom.value
      assert_predicate type.try("invalid"), :failure?
      assert_raises(ArgumentError) { Types::Atom.of(-> { true }) }
    end

    def test_atom_nil_and_optional_semantics
      bare = Types::Atom[nil]
      typed_type = Types::Atom.of(Types::Integer.optional)
      typed = typed_type[nil]

      assert_instance_of Atom, bare
      assert_nil bare.value
      assert_instance_of Atom, typed
      assert_nil typed.value
      refute_predicate typed_type, :optional?
      assert_predicate Types::Atom.of(Types::Integer).optional, :optional?
      assert_nil Types::Atom.of(Types::Integer).optional[nil]
    end

    def test_scalar_variants_and_supported_options
      strict = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(variant: :strict)
      end
      unshared = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(variant: :unshared)
      end
      local = Module.new do
        include ::Dry.Types(default: :params)
        include Farce.DryTypes(variant: :local, scope: :thread)
      end

      assert_instance_of Strict::Atom, strict::Atom[1]
      refute strict.const_defined?(:Counter, false)
      refute strict.const_defined?(:Flag, false)
      assert_instance_of Unshared::Atom, unshared::Atom[1]
      refute unshared.const_defined?(:Counter, false)
      refute unshared.const_defined?(:Flag, false)

      counter = local::Counter["8"]
      flag = local::Flag["true"]
      atom = local::Atom["value"]

      assert_instance_of Local::Counter, counter
      assert_equal :thread, counter.scope
      assert_instance_of Local::Flag, flag
      assert_equal :thread, flag.scope
      assert_instance_of Local::Atom, atom
      assert_equal :thread, atom.scope
    end

    def test_atom_ownership_and_scalar_option_boundaries
      payload = []
      atom = Types::Atom.with(mode: :local)[payload]

      assert_same payload, atom.value
      assert_raises(ArgumentError) { Types::Counter.with(mode: :local) }
      assert_raises(ArgumentError) { Types::Flag.with(mode: :local) }

      factory_mode = Module.new do
        include ::Dry.Types()
        include Farce.DryTypes(mode: :local)
      end

      assert_same payload, factory_mode::Atom[payload].value
      assert_equal 1, factory_mode::Counter[1].value
      assert factory_mode::Flag[true].value
    end

    def test_counter_range_errors_are_dry_failures
      return unless RUBY_ENGINE == "ruby"

      failure = Types::Counter.try(1 << 100)

      assert_predicate failure, :failure?
      assert_instance_of ::Dry::Types::CoercionError, failure.error
      assert_equal :invalid, Types::Counter.call(1 << 100) { :invalid }
    end

    def test_mode_free_farce_inputs_produce_fresh_collections
      vectors = [
        Strict::Vector.new(["1"]),
        Unshared::Vector.new(["2"]),
        Local::Vector.new(["3"])
      ]
      vector_type = Types::Vector.of(Types::Coercible::Integer)
      vectors.each do |source|
        result = vector_type[source]

        assert_instance_of Vector, result
        refute_same source, result
        assert_equal [Integer(source[0])], result.to_a
      end

      source_map = Unshared::Map.new({ "1" => "2" })
      map = Types::Map.map(Types::Coercible::Integer, Types::Coercible::Integer)[source_map]

      assert_instance_of Map, map
      refute_same source_map, map
      assert_equal({ 1 => 2 }, map.to_h)

      source_set = Unshared::Set.new(%w[1 2])
      set = Types::Set.of(Types::Coercible::Integer)[source_set]

      assert_instance_of Set, set
      refute_same source_set, set
      assert_equal [1, 2], set.to_a.sort
    end

    def test_mode_backed_farce_inputs_are_rejected_before_traversal
      vector = Vector.new(mode: :copy)
      vector.push(["payload"], mode: :move)
      type = Types::Vector
      failure = type.try(vector)

      assert_predicate failure, :failure?
      assert_includes failure.error.message, "must be materialized"
      assert_equal :invalid, type.call(vector) { :invalid }

      map = Map.new({ key: 1 })
      set = Set.new([1])

      assert_predicate Types::Map.try(map), :failure?
      assert_predicate Types::Set.try(set), :failure?
      return unless Internal.native_ractors?

      worker = Farce::Ractor.new(vector, &:to_a)
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal [["payload"]], result
    end

    def test_output_modes_and_construction_failures
      assert_raises(ArgumentError) { Types::Vector.with(mode: :move) }
      assert_raises(ArgumentError) { Types::Map.with(mode: :unknown) }

      value = []
      local = Types::Vector.with(mode: :local)[[value]]

      assert_same value, local[0]
      return unless Internal.native_ractors?

      published_value = ["published"]
      published = Types::Vector.with(mode: :make_shareable)[[published_value]]

      assert_same published_value, published[0]
      assert_predicate published_value, :frozen?

      draft = ["draft"]
      copied = Types::Vector.with(mode: :shareable_copy)[[draft]]

      refute_predicate draft, :frozen?
      refute_same draft, copied[0]
      assert_predicate copied[0], :frozen?

      strict = Types::Vector.with(mode: :raise)
      input = [[1]]

      assert_predicate strict.try(input), :failure?
      assert_equal :invalid, strict.call(input) { :invalid }
      assert_raises(::Dry::Types::CoercionError) { strict[input] }
    end

    def test_default_output_is_shareable_and_usable_from_another_ractor
      vector = Types::Vector[[["draft"]]]

      assert Farce::Ractor.shareable?(vector)
      worker = Farce::Ractor.new(vector) do |source|
        source[0]
      end
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal ["draft"], result
      return unless Internal.native_ractors?

      worker = Farce::Ractor.new(vector) do |source|
        value = source[0]
        value << "worker"
      end
      result = worker.respond_to?(:value) ? worker.value : worker.take

      assert_equal %w[draft worker], result
      assert_equal ["draft"], vector[0]
    end

    def test_standard_instance_types_remain_available
      types = ::Dry.Types()
      vector_type = types.Instance(Vector)

      assert_predicate vector_type.try(Vector.new), :success?
      assert_predicate vector_type.try([]), :failure?
    end
  end
end
