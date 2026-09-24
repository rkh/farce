# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Reuse equal frozen values throughout object graphs.
  # Plain strings use Ruby's string deduplication. Arrays, hashes, and Ruby Sets are frozen
  # and cached by default. Other objects are traversed but are not cached unless
  # their class matches {#store}. Modules and classes are skipped by default.
  #
  # Cached objects are held weakly. Keep a reference to a returned object if its
  # identity matters. Shareable results can be reused across Ractors. Other
  # results are cached within the current Ractor.
  # Containers that refer back to a Data value under construction are frozen
  # without being cached, because their hash is not stable yet.
  #
  # @example Use an independent cache
  #   deduper = Farce::Deduper.new
  #   first = deduper.dedup(["name"], copy: true)
  #   deduper.dedup(["name"]).equal?(first) # => true
  class Deduper
    include Shareable::Immutable

    # @api private
    # Create an independent cache with the default skip and store classes.
    def initialize
      @shared = Strict::WeakKeyMap.new
      @local  = Local::WeakKeyMap.new
      @skip   = Strict::Vector[Module]
      @store  = Strict::Vector[Hash, Array, ::Set]
      super
    end

    # Exclude matching objects and their children from subsequent calls.
    # @param modules [Array<Module>] classes or modules matched with is_a?
    # @return [self]
    def skip(*modules)
      @skip.concat(modules)
      self
    end

    # Also freeze and cache objects matching these classes or modules.
    # Define consistent hash, eql?, and == methods for custom value classes.
    # These methods must remain stable after deduplication.
    # @param modules [Array<Module>] classes or modules matched with is_a?
    # @return [self]
    def store(*modules)
      @store.concat(modules)
      self
    end

    # Replace equal values with cached instances, including nested keys and values.
    # By default, mutable containers are updated and cached containers are frozen.
    # Use copy: true to preserve the input. Skipped objects are always returned
    # unchanged. Strings are deduplicated before skip rules are checked.
    # Noncopyable coordination objects follow {Walker.modify}'s in-place behavior.
    # @param object [Object] the root object
    # @param copy [Boolean, Symbol] copying policy passed to {Walker.modify}
    # @param skip [Module, Array<Module>, nil] additional exclusions for this call
    # @return [Object] the deduplicated result
    # @see Walker.modify
    def dedup(object, copy: false, skip: nil)
      skip = skip ? [*@skip, *skip] : @skip.to_a
      dedup!(object, skip, @store.to_a, copy)
    end

    private

    def dedup!(object, skip, store, copy, walker = nil)
      return -object if object.instance_of?(String)
      return object unless Internal.garbage_collectable?(object)

      if skip.any? { object.is_a?(it) }
        walker&.skip(object)
        return object
      end

      if !walker || walker.hashable?(object)
        shareable = Ractor.shareable?(object)
        canonical = (shareable ? @shared : @local).getkey(object)
        return canonical if canonical
      end

      canonical = walker ? walker.traverse :
        Walker.modify(object, copy:, freeze: false) { dedup!(_1, skip, store, copy, _2) }

      return canonical unless store.any? { canonical.is_a?(it) }

      canonical = canonical.dup if copy && !canonical.frozen? && canonical.equal?(object)
      canonical.freeze
      return canonical if walker && !walker.hashable?(canonical)

      if Ractor.shareable?(canonical)
        @shared.store_if_absent(canonical) { true }
        canonical = @shared.getkey(canonical) || canonical
      end

      @local[canonical] = true
      canonical
    end
  end

  DEDUPER = Deduper.new
  private_constant :DEDUPER
end
