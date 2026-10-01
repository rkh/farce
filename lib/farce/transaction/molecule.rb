# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::Molecule Molecule} that is part of a transaction.
    class Molecule < Abstract::Molecule
      include Wrapper

      # @api private
      def initialize(transaction, object)
        super
        @members = object.members
        @atoms = object.each_atom.to_h.transform_values { transaction[it] }
        @fields = @members.to_h { [it, @atoms.fetch(:"#{it}_atom")] }
        @writers = @members.to_h { [:"#{it}=", @atoms.fetch(:"#{it}_atom")] }
        # A field named map or count must read its atom, not call the inherited
        # Enumerable method. Define those readers before method_missing is needed.
        @members.each do |field|
          next unless Enumerable.method_defined?(field)
          atom = @fields.fetch(field)
          define_singleton_method(field) { access { atom.value } }
        end
      end

      # (see Abstract::Molecule#compare_by_identity?)
      # @see Abstract::Molecule#compare_by_identity?
      def compare_by_identity? = access { @object.compare_by_identity? }

      # (see Abstract::Molecule#members)
      # @see Abstract::Molecule#members
      def members = access { @members }

      # (see Abstract::Molecule#atoms)
      # @see Abstract::Molecule#atoms
      def atoms = access { @atoms.keys.freeze }

      # (see Abstract::Molecule#each)
      # @see Abstract::Molecule#each
      def each
        return enum_for(__method__) unless block_given?
        access { @members.each { yield it, @atoms.fetch(:"#{it}_atom").value } }
        self
      end
      alias each_pair each

      # (see Abstract::Molecule#each_atom)
      # @see Abstract::Molecule#each_atom
      def each_atom
        return enum_for(__method__) unless block_given?
        access { @atoms.each { yield _1, _2 } }
        self
      end

      # (see Abstract::Molecule#each_member)
      # @see Abstract::Molecule#each_member
      def each_member
        return enum_for(__method__) unless block_given?
        access { @members.each { yield it } }
        self
      end
      alias each_key each_member

      # (see Abstract::Molecule#each_value)
      # @see Abstract::Molecule#each_value
      def each_value
        return enum_for(__method__) unless block_given?
        each { |_, value| yield value }
        self
      end

      private

      def method_missing(name, *arguments, **options, &block)
        return access { @atoms.fetch(name) } if @atoms.key?(name) && arguments.empty? && options.empty? && !block
        return super unless options.empty? && !block
        return access { @fields.fetch(name).value } if @fields.key?(name) && arguments.empty?
        return write { @writers.fetch(name).value = arguments.first } if @writers.key?(name) && arguments.size == 1
        super
      end

      def respond_to_missing?(name, include_private = false)
        @atoms.key?(name) || @fields.key?(name) || @writers.key?(name) || super
      end

      Wrapper.inherit(self, :compare_by_identity?)
    end
  end
end
