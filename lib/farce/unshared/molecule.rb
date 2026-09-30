# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Unshared
    # A thread-safe record whose atoms retain values directly within one Ractor.
    # Use {Abstract::Molecule.define} to declare named fields.
    # Explicitly supplied atoms keep their own storage and comparison policies.
    class Molecule < Abstract::Molecule
      include Unshareable

      private def create_atom(_, value) = Atom.new(value, compare_by_identity: compare_by_identity?)
    end
  end
end
