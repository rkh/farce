# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "json"
require "psych"

module Farce
  class TestValueSerialization < Test
    def test_json_uses_current_values_in_nested_documents
      atom = Atom.new({ "items" => [1, false, nil] })
      counter = Counter.new(2).increment(3)
      flag = Flag.new
      flag.set

      assert_equal [{ "items" => [1, false, nil] }, 5, true], JSON.parse(JSON.generate([atom, counter, flag]))
      assert_equal JSON.pretty_generate(atom.value), JSON.pretty_generate(atom)
      assert_equal "null", Atom.new.to_json
      assert_equal "false", Flag.new.to_json
    end

    def test_atom_yaml_preserves_value_and_options
      atom = Atom.new({ "items" => [1, false] }, mode: :make_shareable, compare_by_identity: true)
      copy = round_trip(atom)

      assert_equal atom.value, copy.value
      assert_equal :make_shareable, copy.mode
      assert_predicate copy, :compare_by_identity?
      assert Ractor.shareable?(copy)
      copy.store(42)

      assert_equal 42, copy.value
      refute_equal atom.value, copy.value
    end

    def test_atom_variants_preserve_comparison_and_remain_usable
      [Strict::Atom, Local::Atom, Strict::WeakAtom, Unshared::WeakAtom, Local::WeakAtom].each do |type|
        atom = type.new(42, compare_by_identity: true)
        copy = round_trip(atom)

        assert_instance_of type, copy
        assert_equal 42, copy.value
        assert_predicate copy, :compare_by_identity?
        assert copy.compare_and_set(42, 43)
        assert_equal 43, copy.value
        assert_equal "43", copy.to_json
      end
      assert_nil round_trip(Atom.new).value
      refute round_trip(Atom.new(false)).value
    end

    def test_strict_atoms_restore_shareable_collections
      [Strict::Atom, Strict::WeakAtom].each do |type|
        value = Ractor.make_shareable({ "items" => [1, 2] })
        copy = round_trip(type.new(value))
        restored = copy.value

        assert_equal value, restored
        assert Ractor.shareable?(restored) if Internal.native_ractors?

        assert copy.compare_and_set(restored, 42)
      end
    end

    def test_atom_preserves_shareable_value_with_raise_mode
      value = Ractor.make_shareable([1, 2])
      copy = round_trip(Atom.new(value, mode: :raise))

      assert_equal value, copy.value
      assert_equal :raise, copy.mode
      assert Ractor.shareable?(copy.value) if Internal.native_ractors?
    end

    def test_counter_yaml_preserves_initial_value_and_reset
      [Counter, Local::Counter].each do |type|
        counter = type.new(7)
        counter.increment(5)
        copy = round_trip(counter)

        assert_instance_of type, copy
        assert_equal 12, copy.value
        assert_equal 7, copy.initial
        assert Ractor.shareable?(copy)
        assert_same copy, copy.reset
        assert_equal 7, copy.value
        assert_equal 12, counter.value
      end
    end

    def test_flag_yaml_preserves_both_boolean_states
      [Flag, Local::Flag].each do |type|
        [true, false].each do |value|
          copy = round_trip(type.new(value))

          assert_instance_of type, copy
          assert_equal value, copy.value
          assert Ractor.shareable?(copy)
          assert_equal !value, copy.toggle
        end
      end
    end

    def test_local_serialization_uses_current_scope_and_restores_scope
      [Local::Atom, Local::Counter, Local::Flag].each do |type|
        initial, current = type == Local::Flag ? [false, true] : [1, 2]
        local = type.new(initial, scope: :fiber)
        local.value = current
        copy = round_trip(local)

        assert_equal current.to_json, local.to_json
        assert_equal initial.to_json, Fiber.new { local.to_json }.resume
        assert_equal :fiber, copy.scope
        assert_equal current, copy.value
        expected = type == Local::Counter ? initial : current

        assert_equal expected, Fiber.new { copy.value }.resume
      end
    end

    private

    def round_trip(value) = Psych.unsafe_load(Psych.dump(value))
  end
end
