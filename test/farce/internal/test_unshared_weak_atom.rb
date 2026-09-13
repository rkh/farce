# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "test_weak_atom"

module Farce
  module Internal
    class TestUnsharedWeakAtom < TestWeakAtom
      def atom_class = UnsharedWeakAtom
      def shareable_atom? = false

      def test_accepts_mutable_values
        first = []
        second = {}
        atom = atom_class.new(first)

        assert_same first, atom.value
        assert_same(second, atom.update { second })
        assert_same second, atom.value
        assert atom.compare_and_set({}, first)
        assert_same first, atom.value
      end

      def test_uses_native_weak_hooks_when_available
        skip "native weak hooks unavailable" unless Internal.const_defined?(:NATIVE_WEAK_MAPS, false)

        assert_nil atom_class.instance_method(:value).source_location
        atom = atom_class.new([]).freeze

        refute Ractor.shareable?(atom)
        assert_raises(Ractor::Error) { ::Ractor.make_shareable(atom) }
      end

      def test_can_be_created_in_a_non_main_ractor
        skip "native ractors unavailable" unless RUBY_ENGINE == "ruby"
        type = atom_class
        worker = Ractor.new(type) do |klass|
          local = []
          atom = klass.new(local)
          atom.value.equal?(local)
        end

        assert ractor_value(worker)
      end
    end
  end
end
