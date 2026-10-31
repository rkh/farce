# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    class WeakCacheMirror
      include Shareable::Delegated

      CACHED_NIL = Object.new.freeze
      private_constant :CACHED_NIL

      def initialize(shared)
        @shared = shared
        super()
      end

      def store_if_absent(key, &)
        check_frozen!
        return @shared.store_if_absent(key, &) unless Ractor.shareable?(key)

        local = local_cache
        value = local[key]
        return CACHED_NIL.equal?(value) ? nil : value unless nil.equal?(value)

        value = @shared.store_if_absent(key, &)
        local[key] = nil.equal?(value) ? CACHED_NIL : value
        value
      end

      def fetch(key)
        return @shared.fetch(key) { yield(key) } unless Ractor.shareable?(key)

        local = local_cache
        value = local[key]
        return CACHED_NIL.equal?(value) ? nil : value unless nil.equal?(value)

        value = @shared.fetch(key) { return yield(key) }
        local[key] = nil.equal?(value) ? CACHED_NIL : value
        value
      end

      private

      # CRuby's weak-map operations hold the GVL. Shared misses serialize generation,
      # and a retained value cannot be replaced, so local hits need no reservation.
      # Only shareable keys enter the mirror, since mutable strings can change meaning.
      def local_cache
        caches = Ractor.store_if_absent(:"Farce::Internal::WeakCacheMirror") { ObjectSpace::WeakKeyMap.new }
        caches[self] ||= ObjectSpace::WeakMap.new
      end

      def freeze_backend = @shared
    end
  end
end
