# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Strict
    # A Ractor-shareable record whose atoms retain only shareable values.
    # Use {Abstract::Molecule.define} to declare named fields.
    # Explicitly supplied atoms keep their own storage and comparison policies.
    class Molecule < Abstract::Molecule
      include Shareable

      private def create_atom(_, value) = Atom.new(value, compare_by_identity: compare_by_identity?)
    end
  end
end
