# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Shared per-key checkout, mutation, and automatic cleanup behavior for lease maps.
    class LeaseMap < Map
      # Construct a lease map from a Hash-building block.
      # @yield builds the initial key and resource mapping
      # @yieldreturn [Hash] the initial mapping
      def initialize
        raise ArgumentError, "a resource constructor block is required" unless block_given?

        @lease_map = new_internal_lease_map(yield)
        super
      end

      # Acquire one key's resource, waiting until it is available.
      # @param key [BasicObject] the key to acquire
      # @param timeout [Numeric, nil] maximum seconds to wait
      # @yieldparam resource [BasicObject] the acquired resource
      # @return [BasicObject] the resource without a block, or the block result
      # @raise [KeyError] if the key is absent or its entry is deleted while waiting
      # @raise [Farce::TimeoutError] if the timeout expires
      def checkout(key, timeout: nil, &) = internal_lease_map.checkout(key, timeout:, receiver: self, &)

      # Acquire one key's resource immediately if it is available.
      # @param key [BasicObject] the key to acquire
      # @yieldparam resource [BasicObject] the acquired resource
      # @return [BasicObject, nil] the resource or block result, or nil when unavailable
      # @raise [KeyError] if the key is absent
      def try_checkout(key, &) = internal_lease_map.try_checkout(key, receiver: self, &)

      # Return an explicitly checked-out resource, replace it, or delete it with nil.
      # @param key [BasicObject] the checked-out key
      # @param resource [BasicObject, nil] the replacement, or nil to delete the entry
      # @return [self]
      # @raise [Farce::OwnershipError] unless the current Fiber owns an explicit checkout
      # @raise [ArgumentError] if the replacement is boolean
      def checkin(key, resource)
        internal_lease_map.checkin(key, resource, receiver: self)
        self
      end

      # Return the Lease attached to a key's current entry.
      # A retained handle becomes retired when its entry is deleted.
      # @param key [BasicObject] the key to look up
      # @return [Farce::Abstract::Lease] the current entry's Lease
      # @raise [KeyError] if the key is absent
      def lease_for(key) = internal_lease_map.lease_for(key, receiver: self)

      # Keep resources acquired by reads checked out until the block exits.
      # Checkouts already owned before the scope remain owned afterward.
      # Nested scopes return only the resources they acquire, including on exceptions and early returns.
      #
      # @example Nesting automatic checkout scopes
      #   map = Farce::LeaseMap.new { { a: [], b: [] } }
      #   map.auto_lease do
      #     map[:a]       # Held by the outer scope
      #
      #     map.auto_lease do
      #       map[:a]     # Reuses the outer checkout
      #       map[:b]     # Held by the inner scope
      #     end           # Checks in b only
      #
      #     map[:b]       # Acquires b again for the outer scope
      #   end             # Checks in a and b
      #
      # @yield the automatic checkout scope
      # @return [BasicObject] the block result
      def auto_lease(&) = internal_lease_map.auto_lease(&)

      # Read an owned resource or acquire it through the active automatic scope.
      def [](key) = internal_lease_map.read_entry(key).last

      # (see Map#fetch)
      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end

        key, default = arguments
        warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
        present, value = internal_lease_map.read_entry(key)
        return value if present
        return yield(key) if block_given?
        return default if arguments.length == 2

        raise KeyError.new("key not found: #{key.inspect}", receiver: self, key:)
      end

      # Insert or replace a resource. Assigning nil deletes the entry.
      # Assignment waits for another owner. An assignment to an explicitly owned
      # entry replaces its held resource without ending the checkout. Assignment
      # is invalid during a checkout block or an iteration yield.
      # @return [BasicObject, nil] the supplied resource, or the deleted resource
      # @raise [ArgumentError] if the resource is boolean
      def []=(key, resource)
        internal_lease_map.store(key, resource)
      end

      # Read an owned resource or construct an absent resource in an automatic scope.
      # Constructors for the same key run one at a time, outside the map lock.
      # Missing-key assignments wait for construction. Deletion and clear only
      # affect published entries and do not cancel a pending constructor.
      # @param key [BasicObject] the key to read or initialize
      # @yield builds the missing resource without arguments
      # @yieldreturn [BasicObject] a resource other than nil or a boolean
      # @return [BasicObject] the existing or newly constructed resource
      # @raise [LocalJumpError] if no block is given
      # @raise [Farce::OwnershipError] if reading requires ownership or creation lacks an automatic scope
      # @raise [ArgumentError] if the constructor returns nil or a boolean
      def store_if_absent(key, &) = internal_lease_map.store_if_absent(key, &)

      # Delete a key after acquiring and retiring its Lease.
      # @return [BasicObject, nil] the removed resource, or nil if absent
      def delete(key) = internal_lease_map.delete(key)

      # Delete each entry captured when clearing begins.
      # Entries concurrently reinserted under the same key are preserved.
      # @return [self]
      def clear
        internal_lease_map.clear
        self
      end

      # @return [Boolean] whether the key's resource is available
      def available?(key) = internal_lease_map.available?(key)

      # @return [Boolean] whether the key's resource is checked out
      def checked_out?(key) = internal_lease_map.checked_out?(key)

      # @return [Boolean] whether the current Fiber owns the key's checkout
      def owned?(key) = internal_lease_map.owned?(key)

      # (see Map#key?)
      def key?(key) = internal_lease_map.key?(key)

      # (see Map#getkey)
      def getkey(key) = internal_lease_map.getkey(key)

      # (see Map#size)
      def size = internal_lease_map.size

      # (see Map#keys)
      def keys = internal_lease_map.keys

      # LeaseMap keys use equality and values use Lease identity.
      def compare_keys_by_identity? = internal_lease_map.compare_keys_by_identity?
      def compare_values_by_identity? = internal_lease_map.compare_values_by_identity?

      # Top-level keys must be shareable. Managed resources may be unshareable.
      def shareable_keys? = true
      def shareable_values? = false

      # Iterate while leasing only the entry currently being yielded.
      def each(&block)
        return enum_for(__callee__) { size } unless block

        internal_lease_map.each(&block)
        self
      end
      alias each_pair each

      # Iterate over a snapshot of current keys without leasing their resources.
      def each_key(&block)
        return enum_for(__callee__) { size } unless block

        internal_lease_map.each_key(&block)
        self
      end

      # Iterate while leasing only the value currently being yielded.
      def each_value(&block)
        return enum_for(__callee__) { size } unless block

        internal_lease_map.each_value(&block)
        self
      end

      # Return key and Lease handle pairs.
      # Unlike iteration, this method never checks resources out.
      # @return [Array<Array(BasicObject, Farce::Abstract::Lease)>]
      def to_a = internal_lease_map.handles

      # Return a key to Lease handle mapping.
      # Unlike iteration, this method never checks resources out.
      # @return [Hash{BasicObject => Farce::Abstract::Lease}]
      def to_h = to_a.to_h

      # Return the current Lease handles.
      # @return [Array<Farce::Abstract::Lease>]
      def values = to_h.values

      # Show keys and Lease states without checking resources out.
      def inspect
        states = to_a.map { |key, lease| "#{key.inspect} => #{lease_state(lease)}" }.join(", ")
        "#<#{self.class.name} {#{states}}>"
      end

      private

      def each_for_inspect
        return enum_for(__method__) { size } unless block_given?

        to_a.each { |key, lease| yield key, lease_state(lease) }
        self
      end

      def internal_lease_map = @lease_map
      def new_internal_lease_map(_) = raise(NoMethodError, "abstract lease map storage")

      def lease_state(lease)
        return :retired if lease.retired?
        return :available if lease.available?
        return :owned if lease.owned?

        :checked_out
      end
    end
  end
end
