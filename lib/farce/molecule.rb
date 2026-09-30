# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable record with independently atomic fields.
  # Values use the selected transfer mode, just like {Farce::Atom}.
  # An explicitly supplied atom keeps its own settings.
  #
  # This class is an alternative to Ruby's Struct or Data classes.
  #
  # @example Updating a named field atomically
  #   Job = Farce::Molecule.define(:status, :attempts)
  #   job = Job.new(status: :pending, attempts: 0)
  #   job.attempts_atom.update { |count| count + 1 }
  #   job.status = :running
  #   job.to_h # => { status: :running, attempts: 1 }
  class Molecule < Farce::Abstract::Molecule
    include Shareable

    # Create a record class with defaults for newly created atoms.
    # @!macro modes
    # @param fields [Array<Symbol, String>] the field names
    # @param mode [Symbol, nil] the default transfer mode, or nil for :copy
    # @param compare_by_identity [Boolean, nil] the default comparison policy
    # @return [Class<Molecule>]
    def self.define(*fields, mode: nil, **)
      subclass = super(*fields, **)
      subclass.class_eval "def self.default_mode = #{mode.to_sym.inspect}", __FILE__, __LINE__ unless nil.equal?(mode)
      subclass
    end

    # @return [Symbol] the default transfer mode for new records
    def self.default_mode = :copy

    # @!visibility private
    def self.define_member(field)
      return super unless field == :mode
      raise ArgumentError, "#{field.inspect} is not a valid field name"
    end
    private_class_method :define_member

    # Initialize fields and optionally override the record class defaults.
    # @!macro modes
    # @param mode [Symbol, nil] the transfer mode, or nil for the class default
    # @param compare_by_identity [Boolean, nil] the comparison policy, or nil for the class default
    # @see Abstract::Molecule#initialize
    def initialize(*, mode: nil, **)
      @mode = mode&.to_sym || self.class.default_mode
      super(*, **)
    end

    # The default mode used to transfer values between Ractors.
    # @return [Symbol]
    attr_reader :mode

    private def create_atom(_, value) = Atom.new(value, mode:, compare_by_identity: compare_by_identity?)
  end
end
