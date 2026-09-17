# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Portable per-key ownership and lifecycle implementation for LeaseMap.
    class LeaseMap
      AUTO_LEASE_CONTEXTS = Object.new.freeze
      private_constant :AUTO_LEASE_CONTEXTS

      def initialize(initial_mapping, lease_class:, registry_class:)
        raise TypeError, "lease map initializer must return a Hash" unless initial_mapping.is_a?(Hash)

        @lease_class    = lease_class
        @registry_lock  = Lock.new
        @creation_locks = KeyLockMap.new(registry_class:)

        initial_mapping.each_key { validate_key!(it) }
        initial_mapping.each_value { validate_resource!(it) }

        entries   = initial_mapping.to_h { |key, resource| [key, new_lease(resource)] }
        @registry = registry_class.new(entries, compare_values_by_identity: true)

        return unless @registry.ractor_shareable?

        Ractor.make_shareable(self)
        freeze
      end

      def checkout(key, receiver:, timeout: nil, &block)
        lease = fetch_lease(key, receiver:)
        if block
          entered = false
          lease.checkout(timeout:) do |resource|
            entered = true
            block.call(resource)
          end
        else
          context = auto_context
          context ? acquire_for_context(lease, context, timeout:) : lease.checkout(timeout:)
        end
      rescue RetiredLeaseError
        raise if entered
        prune_binding(key, lease)
        raise_missing_key(key, receiver)
      end

      def try_checkout(key, receiver:, &block)
        lease = fetch_lease(key, receiver:)
        if block
          entered = false
          lease.try_checkout do |resource|
            entered = true
            block.call(resource)
          end
        else
          context = auto_context
          context ? acquire_for_context(lease, context, try: true) : lease.try_checkout
        end
      rescue RetiredLeaseError
        raise if entered
        prune_binding(key, lease)
        raise_missing_key(key, receiver)
      end

      def checkin(key, resource, receiver:)
        lease = fetch_lease(key, receiver:)

        if nil.equal?(resource)
          unless explicitly_owned?(lease) && !scope_managed?(lease)
            raise OwnershipError, "the current Fiber does not own an explicit checkout"
          end

          delete_entry(key, lease)
          return self
        end

        lease.checkin(resource)
        self
      end

      def read_entry(key)
        lease = current_lease(key)
        return [false, nil] unless lease

        resource = if lease.owned?
                     owned_resource(lease)
                   elsif (context = auto_context)
                     acquire_for_context(lease, context)
                   else
                     raise RetiredLeaseError, "lease has been retired" if lease.retired?
                     raise OwnershipError, "the current Fiber does not own the key checkout"
                   end

        [true, resource]
      rescue RetiredLeaseError
        prune_binding(key, lease)
        [false, nil]
      end

      def lease_for(key, receiver:) = fetch_lease(key, receiver:)

      def store(key, resource)
        validate_key!(key)
        return delete(key) if nil.equal?(resource)
        validate_resource!(resource)

        lease = nil
        inserted = false
        context = auto_context
        @creation_locks.synchronize(key) do
          Thread.handle_interrupt(INTERRUPT_MASK) do
            @registry_lock.synchronize do
              lease = @registry[key]
              if lease&.retired?
                @registry.delete(key)
                lease = nil
              end
              unless lease
                lease = new_lease(resource)
                @registry[key] = lease
                acquire_for_context(lease, context) if context
                inserted = true
              end
            end
          end
        end
        return resource if inserted

        replace(key, lease, resource)
      rescue RetiredLeaseError
        prune_binding(key, lease)
        retry
      end

      def store_if_absent(key, &)
        raise LocalJumpError, "no block given" unless block_given?
        validate_key!(key)

        while true
          present, resource = read_entry(key)
          return resource if present

          context = auto_context
          raise OwnershipError, "resource construction requires an automatic lease scope" unless context

          inserted = false
          @creation_locks.synchronize(key) do
            next if current_lease(key)

            Thread.handle_interrupt(INTERRUPT_MASK) do
              resource = Thread.handle_interrupt(Exception => :immediate, &)
              validate_resource!(resource)
              @registry_lock.synchronize do
                lease          = new_lease(resource)
                @registry[key] = lease
                resource       = acquire_for_context(lease, context)
                inserted       = true
              end
            end
          end
          return resource if inserted
        end
      end

      def delete(key)
        lease = current_lease(key)
        return unless lease

        delete_entry(key, lease)
      rescue RetiredLeaseError
        prune_binding(key, lease)
        nil
      end

      def clear
        entries_snapshot.each do |key, lease|
          delete_entry(key, lease)
        rescue RetiredLeaseError
          prune_binding(key, lease)
        end
        self
      end

      def auto_lease
        raise LocalJumpError, "no block given" unless block_given?

        contexts = context = nil
        pushed = false
        Thread.handle_interrupt(INTERRUPT_MASK) do
          contexts = auto_contexts
          context = {}.compare_by_identity
          (contexts[self] ||= []) << context
          pushed = true
        end
        yield
      ensure
        if pushed
          Thread.handle_interrupt(INTERRUPT_MASK) do
            cleanup_context(context)
          ensure
            stack = contexts[self]
            stack.pop
            contexts.delete(self) if stack.empty?
          end
        end
      end

      def available?(key)             = current_lease(key)&.available? || false
      def checked_out?(key)           = current_lease(key)&.checked_out? || false
      def owned?(key)                 = current_lease(key)&.owned? || false
      def key?(key)                   = !current_lease(key).nil?
      def size                        = entries_snapshot.size
      def keys                        = entries_snapshot.map(&:first)
      def compare_keys_by_identity?   = @registry.compare_keys_by_identity?
      def compare_values_by_identity? = true
      def getkey(key)                 = current_lease(key) && @registry.getkey(key)

      def each
        return enum_for(__method__) { size } unless block_given?

        entries_snapshot.each do |key, lease|
          next unless current_binding?(key, lease)

          if lease.owned?
            yield key, owned_resource(lease)
          else
            entered = false
            begin
              lease.checkout do |resource|
                entered = true
                yield key, resource
              end
            rescue RetiredLeaseError
              raise if entered

              prune_binding(key, lease)
            end
          end
        end
        self
      end

      def each_key
        return enum_for(__method__) { size } unless block_given?

        keys.each { yield it }
        self
      end

      def each_value
        return enum_for(__method__) { size } unless block_given?

        each { |_key, value| yield value }
        self
      end

      def handles = entries_snapshot

      private

      def new_lease(resource) = @lease_class.new { resource }

      def current_lease(key)
        @registry_lock.synchronize do
          lease = @registry[key]
          if lease&.retired?
            @registry.delete(key) if @registry[key].equal?(lease)
            lease = nil
          end
          lease
        end
      end

      def fetch_lease(key, receiver:)
        current_lease(key) || raise_missing_key(key, receiver)
      end

      def raise_missing_key(key, receiver)
        raise KeyError.new("key not found: #{key.inspect}", receiver:, key:)
      end

      def replace(key, lease, resource)
        if lease.owned?
          replace_owned_resource(lease, resource)
          return resource
        end

        original  = nil
        completed = false
        begin
          if (context = auto_context)
            original = acquire_for_context(lease, context)
            replace_owned_resource(lease, resource)
          else
            lease.__send__(:checkout_with_handoff) { |value| original = value }
            lease.checkin(resource)
          end
          completed = true
        ensure
          if !completed && original && lease.owned? && !lease.retired?
            if scope_managed?(lease)
              lease.__send__(:checkin_scope, owned_resource(lease))
            else
              lease.checkin(original)
            end
          end
        end
        resource
      rescue RetiredLeaseError
        prune_binding(key, lease)
        raise
      end

      def delete_entry(key, lease)
        return unless current_binding?(key, lease)

        acquired = false
        resource = nil
        begin
          if lease.owned?
            resource = owned_resource(lease)
          else
            lease.__send__(:checkout_with_handoff) do |value|
              resource = value
              acquired = true
            end
          end

          removed = Thread.handle_interrupt(INTERRUPT_MASK) do
            @registry_lock.synchronize do
              next false unless @registry[key].equal?(lease)

              @registry.delete(key)
              remove_auto_resource(lease)
              lease.retire
              true
            end
          end
          return resource if removed
        ensure
          lease.checkin(resource) if acquired && lease.owned? && !lease.retired?
        end
        nil
      end

      def entries_snapshot
        @registry_lock.synchronize do
          entries = @registry.each_pair.to_a
          entries.reject! do |key, lease|
            next false unless lease.retired?

            @registry.delete(key) if @registry[key].equal?(lease)
            true
          end
          entries
        end
      end

      def current_binding?(key, lease)
        @registry_lock.synchronize { @registry[key].equal?(lease) && !lease.retired? }
      end

      def prune_binding(key, lease)
        return unless lease

        @registry_lock.synchronize { @registry.delete(key) if @registry[key].equal?(lease) && lease.retired? }
      end

      def owned_resource(lease) = lease.__send__(:owned_resource)

      def replace_owned_resource(lease, resource)
        lease.__send__(:replace_owned_resource, resource)
      end

      def auto_contexts
        Storage.fiber.store_if_absent(AUTO_LEASE_CONTEXTS, mode: :strong) { {}.compare_by_identity }
      end

      def auto_context
        auto_contexts[self]&.last
      end

      def acquire_for_context(lease, context, timeout: nil, try: false)
        method  = try ? :try_checkout_with_handoff : :checkout_with_handoff
        options = try ? {} : { timeout: }
        already_registered = context.key?(lease)
        lease.__send__(method, **options) do
          lease.__send__(:mark_scope_managed)
          register_context_resource(context, lease)
        end
      rescue Exception # rubocop:disable Lint/RescueException
        context.delete(lease) if !already_registered && context.key?(lease)
        raise
      end

      def register_context_resource(context, lease)
        context[lease] = true
      end

      def remove_auto_resource(lease)
        auto_contexts[self]&.each { it.delete(lease) }
      end

      def cleanup_context(context)
        Thread.handle_interrupt(INTERRUPT_MASK) do
          failure = nil
          context.each_key.to_a.reverse_each do |lease|
            next if lease.retired? || !lease.owned? || !scope_managed?(lease)

            begin
              lease.__send__(:checkin_scope, owned_resource(lease))
            rescue Exception => e # rubocop:disable Lint/RescueException
              failure ||= e
            end
          end
          raise failure if failure
        end
      end

      def validate_resource!(resource)
        return unless nil.equal?(resource) || true.equal?(resource) || false.equal?(resource)

        raise ArgumentError, "lease resource cannot be nil or boolean"
      end

      def validate_key!(key)
        return if Ractor.shareable?(key)

        raise Ractor::IsolationError, "key must be Ractor-shareable"
      end

      def explicitly_owned?(lease) = lease.__send__(:explicitly_owned?)
      def scope_managed?(lease) = lease.__send__(:scope_managed?)
    end
  end
end
