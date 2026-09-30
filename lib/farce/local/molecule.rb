# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Local
    # A shareable record with independent field values in each selected scope.
    # Use {Abstract::Molecule.define} to declare named fields.
    # Explicitly supplied atoms keep their own storage and comparison policies.
    class Molecule < Abstract::Molecule
      include Shareable

      # Create a record class with a default scope for newly created field atoms.
      # @!macro scopes
      # @param fields [Array<Symbol, String>] the field names
      # @param scope [Symbol, nil] the default scope, or nil to inherit
      # @param compare_by_identity [Boolean, nil] the default comparison policy
      # @return [Class<Molecule>]
      def self.define(*fields, scope: nil, **)
        unless scope.nil? || Internal::Storage::SCOPES.include?(scope)
          raise ArgumentError, "Invalid scope: #{scope.inspect}"
        end

        subclass = super(*fields, **)
        subclass.class_eval "def self.default_scope = #{scope.inspect}", __FILE__, __LINE__ unless scope.nil?
        subclass
      end

      # @return [Symbol] the default scope for new records
      def self.default_scope = :ractor

      # Initialize fields using this variant's atoms.
      # @!macro scopes
      # @param scope [Symbol] the scope for new field atoms, defaulting to the record class scope
      # @see Abstract::Molecule#initialize
      def initialize(*, scope: self.class.default_scope, **)
        @scope = scope
        super(*, **)
      end

      # @return [Symbol] the scope used by newly created field atoms
      attr_reader :scope

      private def create_atom(_, value) = Atom.new(value, scope:, compare_by_identity: compare_by_identity?)
    end
  end
end
