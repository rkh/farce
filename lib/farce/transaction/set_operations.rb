# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # Initializes Set and SortedSet wrappers with a transactional backing map.
    # Abstract::Set's methods operate directly on this wrapper's @map. The map
    # owns the snapshot and commit logic. Only membership settings and transfer
    # checks belong here, because some transfers change values before insertion.
    # @!visibility private
    module SetOperations # :nodoc: all
      include Wrapper

      READ_HELPERS = %i[
        each size length empty? count include? member? === compare_by_identity? weak?
        == eql? hash subset? proper_subset? superset? proper_superset? intersect? disjoint? <=>
        <= < >= > join inspect to_s to_set each_stored equality_index ordered? public_stored
      ].freeze
      WRITE_HELPERS = %i[add << add? delete delete? clear merge subtract].freeze

      def initialize(transaction, object, map)
        super(transaction, object)
        compose(:normalizer, :compare_by_identity, :manager, map:)
        @value_modes = object.method(:value_modes?).call
      end

      def value_modes? = access { @value_modes }

      private

      def add_mode_value?(element, mode:)
        selected = UNDEFINED.equal?(mode) || mode.nil? ? @manager.mode : mode
        if %i[move make_shareable dedup proxy].include?(selected)
          raise TypeError, "#{selected} transfers do not support transactions"
        end
        super
      end

      def unwrap_entry(key, entry)
        raise TypeError, "move envelopes do not support transactions" if Envelope::Move === entry.payload
        super
      end
    end

    private_constant :SetOperations
  end
end
