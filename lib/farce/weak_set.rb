# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable concurrent set that retains prepared elements weakly.
  # Elements support :raise (the default), :make_shareable, and :dedup.
  # Membership refers to the prepared element itself. Lookup and deletion do
  # not freeze or deduplicate their arguments. Already-shareable elements pass
  # through unchanged, as with other mode-backed containers.
  #
  # With :dedup, the stored canonical element can differ from the input.
  # Keeping only the input alive may not keep that element alive. Callers are
  # responsible for retaining elements they need. Both add and add? retain
  # their usual set return values rather than returning the stored element.
  #
  # @example Tracking an object without keeping it alive
  #   resource = []
  #   set = Farce::WeakSet.new(mode: :make_shareable)
  #   set.add(resource)
  #   set.first.equal?(resource) # => true
  #   resource = nil
  #   # After collection, the set can become empty.
  class WeakSet < Farce::Abstract::WeakSet
    include Shareable::Delegated

    # The default mode used to prepare elements for insertion.
    # @return [Symbol] :raise, :make_shareable, or :dedup
    def mode = @manager.mode

    # (see Abstract::Set#include?)
    def include?(element)
      key = lookup_key(normalize_element(element))
      !MISSING_KEY.equal?(key) && @map.key?(key)
    end
    alias member? include?
    alias === include?

    # (see Abstract::Set#delete)
    def delete(element)
      check_frozen!
      key = lookup_key(normalize_element(element))
      @map.delete(key) unless MISSING_KEY.equal?(key)
      self
    end

    # (see Abstract::Set#delete?)
    def delete?(element) # rubocop:disable Naming/PredicateMethod
      check_frozen!
      key = lookup_key(normalize_element(element))
      self unless MISSING_KEY.equal?(key) || !@map.delete(key)
    end

    protected

    # Canonical imports bypass normalization, but still prepare external elements.
    def add_stored(key, value) = super(@manager.wrap(key), value)

    private

    def initialize_value_mode(mode)
      mode = :raise if UNDEFINED.equal?(mode)
      @manager = Internal::WeakModeManager.new(mode:)
    end

    def add_normalized?(element, mode: UNDEFINED)
      selected = UNDEFINED.equal?(mode) ? nil : mode
      super(@manager.wrap(element, mode: selected))
    end

    def lookup_key(element)
      return element if Ractor.shareable?(element)
      return MISSING_KEY if identity_membership?(element)
      structural_key(element)
    end

    def new_map(entries = nil, **)
      entries = entries&.map { |element, value| [@manager.wrap(element), value] }
      Strict::WeakMap.new(entries, **)
    end
  end
end
