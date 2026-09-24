# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Storage
      SCOPES = %i[ractor thread_group thread fiber_storage fiber].freeze

      class ThreadSafe < Storage
        def initialize
          @strong_locks = {}
          @weak_locks   = ObjectSpace::WeakKeyMap.new
          super
        end

        def store_if_absent(key, mode: :auto)
          map   = map_for(key, mode)
          value = map[key]
          return value unless value.nil?

          mutex_map = Internal.garbage_collectable?(key) ? @weak_locks : @strong_locks
          mutex     = mutex_map[key] || @mutex.synchronize { mutex_map[key] ||= Mutex.new }

          mutex.synchronize do
            map[key] = yield unless map.key?(key)
            map[key]
          end
        end
      end

      def self.[](key, scope: :ractor, **) = scope(scope)[key, **]

      def self.[]=(key, scope = :ractor, mode = :auto, value) # rubocop:disable Style/OptionalArguments
        scope(scope)[key, mode] = value
      end

      def self.dig(*, scope: :ractor, **) = scope(scope).dig(*, **)

      def self.store_if_absent(key, scope: :ractor, **, &) = scope(scope).store_if_absent(key, **, &)

      def self.scope(scope, raise_exception: true)
        case scope
        when :global
          raise ArgumentError, "global scope is not supported" if raise_exception
        when Symbol
          return __send__(scope) if SCOPES.include?(scope)
          return unless raise_exception
          raise ArgumentError, "Invalid scope: #{scope.inspect}"
        when Class
          storage = scope(scope.name.downcase.to_sym, raise_exception: false)
          return storage if storage
          raise ArgumentError, "Invalid scope: #{scope.inspect}" if raise_exception
        when Storage
          scope
        else
          raise ArgumentError, "Invalid scope: #{scope.inspect}" if raise_exception
        end
      end

      def self.ractor
        return MAIN_STORAGE if Ractor.main?
        Ractor.store_if_absent(name) { ThreadSafe.new }
      end

      def self.thread_group(thread = Thread.current)
        group    = thread.is_a?(ThreadGroup) ? thread : thread.group
        by_group = ractor.store_if_absent(:thread_groups) { ThreadSafe.new }
        by_group.store_if_absent(group) { ThreadSafe.new }
      end

      def self.thread(thread = Thread.current)
        thread    = Internal.storage_thread(thread)
        root      = Internal.native_ractors? ? ractor : MAIN_STORAGE
        by_thread = root.store_if_absent(:threads) { Storage.new }
        by_thread[thread] ||= Storage.new
      end

      def self.fiber_storage = Fiber[name] ||= Storage.new

      def self.fiber(fiber = Fiber.current)
        by_fiber = ractor.store_if_absent(:fibers) { Storage.new }
        by_fiber[fiber] ||= Storage.new
      end

      def initialize
        @mutex  = Mutex.new
        @strong = nil
        @weak   = nil
      end

      def [](key, positional_mode = nil, mode: :auto)
        map = map_for(key, positional_mode || mode, create: false)
        map[key] if map
      end

      def []=(key, mode = :auto, value) # rubocop:disable Style/OptionalArguments
        map_for(key, mode)[key] = value
      end

      def key?(key, mode = :auto) = map_for(key, mode, create: false)&.key?(key)

      def store_if_absent(key, mode: :auto)
        map = map_for(key, mode)
        map[key] = yield unless map.key?(key)
        map[key]
      end

      def dig(key, *keys, mode: :auto)
        value = self[key, mode]
        keys.empty? ? value : value&.dig(*keys)
      end

      def clear
        @mutex.synchronize do
          @strong&.clear
          @weak&.clear
        end
      end

      private

      def strong(create: true)
        return @strong unless create && !@strong
        @mutex.synchronize { @strong ||= {} }
      end

      def weak(create: true)
        return @weak unless create && !@weak
        @mutex.synchronize { @weak ||= ObjectSpace::WeakKeyMap.new }
      end

      def map_for(key, mode, **)
        case mode
        when :auto   then return strong(**) if key.instance_of?(String)
        when :strong then return strong(**)
        when :weak # no-op
        else raise ArgumentError, "Invalid mode: #{mode.inspect}"
        end
        Internal.garbage_collectable?(key) ? weak(**) : strong(**)
      end
    end

    # shareable_constant_value: none
    MAIN_STORAGE = Storage::ThreadSafe.new
  end
end
