# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A record whose fields are independently atomic references.
    #
    # Define a record class with {.define}, then read or assign its named fields.
    # Use each field's `<name>_atom` for updates, comparisons, and waits.
    # Operations on several fields are not a transaction or a consistent snapshot.
    class Molecule
      include Internal::Freeze::Tracked
      include Enumerable

      EMPTY_ARRAY = [].freeze
      private_constant :EMPTY_ARRAY

      ACCESSORS = Module.new do
        def get        = public_send(:"#{__callee__}_atom").value
        def set(value) = public_send(:"#{__callee__.to_s.delete_suffix("=")}_atom").value = value
        def atom       = @molecule_atoms.fetch(__callee__, nil)

        def atom=(value)
          @molecule_atoms[__callee__.to_s.delete_suffix("=").to_sym] = value
        end
      end

      private_constant :ACCESSORS

      # Create a record class with readers, writers, and `<name>_atom` accessors.
      # Missing initial values default to nil. Generated classes may be subclassed.
      # @param fields [Array<Symbol, String>] unique field names
      # @param compare_by_identity [Boolean, nil] the default comparison policy, or nil to inherit
      # @return [Class<Molecule>] the record class
      # @raise [ArgumentError] if names conflict with the record interface
      def self.define(*fields, compare_by_identity: nil)
        fields = fields.map(&:to_sym)
        names  = fields.flat_map { [it, :"#{it}=", :"#{it}_atom", :"#{it}_atom="] }

        conflicts = names.any? do |name|
          next true if name == :freeze
          next false unless method_defined?(name) || private_method_defined?(name)
          instance_method(name).owner != Enumerable
        end

        if names.uniq.length != names.length || conflicts
          raise ArgumentError, "field names must be unique and must not override the molecule interface"
        end

        Class.new(self) do
          singleton_class.class_eval { undef define }
          unless nil.equal?(compare_by_identity)
            class_eval "def self.compare_by_identity? = #{(!!compare_by_identity).inspect}", __FILE__, __LINE__ - 1
          end

          atoms = []
          members = fields.map do |field|
            define_member(field)
            atoms << :"#{field}_atom"
            field
          end

          @atoms   = Ractor.make_shareable(atoms.freeze)
          @members = Ractor.make_shareable(members.freeze)
        end
      end

      # @return [Boolean] the default comparison policy for new records
      def self.compare_by_identity? = false

      # @!visibility private
      def self.define_member(field)
        raise ArgumentError, "#{field.inspect} is not a valid field name" if field == :compare_by_identity
        if field =~ /\A[a-z_]\w*\z/i
          attr_accessor :"#{field}_atom"
          private :"#{field}_atom="
          class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{field} = self.#{field}_atom.value

            def #{field}=(value)
              self.#{field}_atom.value = value
            end
          RUBY
        else
          define_method(:"#{field}_atom",  ACCESSORS.instance_method(:atom))
          define_method(:"#{field}_atom=", ACCESSORS.instance_method(:atom=))
          define_method(field,             ACCESSORS.instance_method(:get))
          define_method(:"#{field}=",      ACCESSORS.instance_method(:set))
          private :"#{field}_atom="
        end
      end
      private_class_method :define_member

      # @return [Array<Symbol>] the atom accessor names in declaration order
      def self.atoms
        return @atoms if defined?(@atoms) && @atoms
        return superclass.atoms if superclass.respond_to?(:atoms)
        EMPTY_ARRAY
      end

      # @return [Array<Symbol>] the field names in declaration order
      def self.members
        return @members if defined?(@members) && @members
        return superclass.members if superclass.respond_to?(:members)
        EMPTY_ARRAY
      end

      # Initialize fields by position or name. A field may only be supplied once.
      # Existing {Atom} instances are retained directly, preserving their policy.
      # @param input [Array<BasicObject>] values in declaration order
      # @param attributes [Hash{Symbol => BasicObject}] values by field name
      # @param compare_by_identity [Boolean, nil] the comparison policy, or nil for the class default
      # @raise [ArgumentError] for unknown, repeated, or excess values
      def initialize(*input, compare_by_identity: nil, **attributes)
        raise ArgumentError, "too many positional values" if input.length > members.length
        @compare_by_identity = compare_by_identity.nil? ? self.class.compare_by_identity? : !!compare_by_identity # rubocop:disable Style/DoubleNegation
        @molecule_atoms = {}
        input.each_with_index { initialize_atom(members[_2], _1) }
        attributes.each { initialize_atom(_1, _2) }
        members.each { initialize_atom(it, nil) unless public_send(:"#{it}_atom") }
        @molecule_atoms.freeze
        super()
      end

      # Enroll every field in one explicit transaction.
      # Field atom accessors return the same wrappers as transaction[atom].
      # @return [Farce::Transaction::Molecule]
      def transaction_wrapper(transaction) = Transaction::Molecule.new(transaction, self)

      # Whether newly created atoms compare by identity instead of equality.
      # Explicitly supplied atoms retain their own comparison policy.
      # @return [Boolean]
      def compare_by_identity? = @compare_by_identity

      # (see .atoms)
      def atoms = self.class.atoms

      # (see .members)
      def members = self.class.members

      # Yield field names and current values in declaration order.
      # @yieldparam member [Symbol] the field name
      # @yieldparam value [BasicObject] its current value
      # @return [Array<Symbol>, Enumerator]
      def each
        return enum_for(:each) unless block_given?
        members.each { yield it, public_send(it) }
      end
      alias each_pair each

      # Yield atom accessor names and atomic references in declaration order.
      # @yieldparam name [Symbol] the atom accessor name
      # @yieldparam atom [Atom] the field's atomic reference
      # @return [Array<Symbol>, Enumerator]
      def each_atom
        return enum_for(:each_atom) unless block_given?
        atoms.each { yield it, public_send(it) }
      end

      # Yield field names in declaration order.
      # @return [Array<Symbol>, Enumerator]
      def each_member
        return enum_for(:each_member) unless block_given?
        members.each { yield it }
      end
      alias each_key each_member

      # Yield current field values in declaration order.
      # @return [Array<Symbol>, Enumerator]
      def each_value
        return enum_for(:each_value) unless block_given?
        members.each { yield public_send(it) }
      end

      # Prevent field replacement and atom updates without freezing stored values.
      # Coordinate with writers before freezing. This is not a snapshot operation.
      # @return [self]
      def freeze
        return self if frozen?
        each_atom { |_, atom| atom.freeze }
        super
      end

      private

      # @abstract Build the atomic reference for one field.
      # @param key [Symbol] the field name
      # @param value [BasicObject] its initial value
      # @return [Atom]
      def create_atom(_key, _value) = raise NoMethodError, "create_atom must be implemented in the subclass"

      def initialize_atom(key, value)
        getter = :"#{key}_atom"
        setter = :"#{key}_atom="

        raise ArgumentError, "#{key.inspect} is not a valid member" unless respond_to?(getter)
        current = public_send(:"#{key}_atom")

        if respond_to?(setter, true)
          raise ArgumentError, "#{key} has already been initialized" if current
          value = create_atom(key, value) unless Atom === value
          __send__(:"#{key}_atom=", value)
        else
          raise TypeError, "expected #{getter.inspect} to return an Atom" unless current.is_a?(Atom)
          current.value = value
        end
      end
    end
  end
end
