# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ActiveSupport Integration
require "farce/integrations/active_support"

# ActiveSupport's blank? already checks empty?
# Therefore Vector/Map/Set implementations do not need additional blank? checks.
#-

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # @api private
    class Vault
      # rubocop:disable-next Naming/PredicatePrefix
      if defined?(Manager)
        class Manager
          def is_blank(key, _, port) = respond(port, [true, @data[key].blank?].freeze)
        end

        def is_blank?(key) = execute(:is_blank, key)
      else
        def is_blank?(key) = @data[key].blank?
      end
    end
  end

  module Abstract
    class Atom
      # @!macro active_support
      # @return [Boolean] true if the atom's value is blank, false otherwise.
      def blank? = internal_atom.value.blank?
    end

    module Value
      # @!macro active_support
      # @return [Boolean] true if the value is blank, false otherwise.
      def blank? = value.blank?
    end
  end

  class Atom
    # @!macro active_support
    # @return [Boolean] true if the atom's value is blank, false otherwise.
    def blank?
      current = internal_atom.value
      NIL_VALUE.equal?(current) || current.blank?
    end
  end

  class Envelope
    # @!macro active_support
    # Checks if the envelope's value is blank without claiming it.
    # @return [Boolean] true if the envelope's value is blank or inaccessible, false otherwise.
    def blank?
      if !claimed? && (vault = comparison_vault)
        result = vault.is_blank?(comparison_key)
        # A concurrent claim may have removed the value from the vault.
        return result unless claimed?
      end
      return true unless owned?

      value.blank?
    end
  end
end
