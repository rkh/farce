# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/unshared_weak_map"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # A map entry owned by the Vault Ractor. Its change counter is the only
    # part used directly by callers in other Ractors.
    class VaultWeakMapCell
      attr_reader :token

      def initialize(key_reference, weak_values:)
        @token = Object.new
        @key = key_reference
        @weak_values = weak_values
        @value = nil
        @present = @retired = false
        @claim = nil
        @changes = Atom.new(0)
      end

      def read
        return [:retired] if @retired
        return busy if @claim
        alive, key = @key.read
        return [:dead] unless alive
        return [:ok, false, nil, @changes, @changes.value, key] unless @present

        alive, value = read_value
        alive ? [:ok, true, value, @changes, @changes.value, key] : [:dead]
      end

      def claim(ticket)
        current = read
        return current unless current.first == :ok

        @claim = ticket
        current[0] = :claimed
        current.freeze
      end

      def finish(ticket, action, value = nil)
        return [:stale] unless @claim.equal?(ticket)

        remove = false
        if action == :store && @key.read.first
          write_value(value)
          @present = true
        elsif action == :delete || (action == :abort && !@present)
          remove = true
          retire
        end
        @claim = nil
        changed unless @retired
        [remove ? :remove : :ok, @changes, @changes.value].freeze
      end

      def store(value)
        return if @retired || @claim || !@key.read.first

        write_value(value)
        @present = true
        changed
      end

      def delete
        state = read
        return state if state.first == :busy
        return [:missing] unless state.first == :ok && state[1]

        value = state[2]
        retire
        [:ok, value].freeze
      end

      def lookup_key
        return [false, nil] if @retired
        alive, key = @key.read
        return [false, nil] unless alive
        return [true, key] if @claim || !@present

        [read_value.first, key]
      end

      def retired? = @retired
      def release; end

      def retire
        return if @retired

        @retired = true
        @present = false
        @claim = @key = @value = nil
        changed
      end

      def retire_if_dead
        return [false, false, nil] if @retired || @claim

        alive, key = @key.read
        return [false, false, nil] if alive && (!@present || read_value.first)

        retire
        [true, alive, key]
      end

      private

      def busy = [:busy, @changes, @changes.value].freeze

      def changed = @changes.update { |generation| generation + 1 }

      def read_value
        return [true, @value] unless @weak_values
        @value.read
      end

      def write_value(value)
        @value = @weak_values ? UnsharedWeakMapWeakReference.for(value) : value
      end
    end
    private_constant :VaultWeakMapCell

    # Owner-side state for one fallback weak map. It does not retain the token
    # used by the Vault registry.
    class VaultWeakMapState
      def initialize(weak_keys:, weak_values:, compare_keys_by_identity:)
        @weak_values = weak_values
        @changes = Atom.new(0)
        @claims = {}.compare_by_identity
        index_class = if weak_keys
                        compare_keys_by_identity ? UnsharedWeakIdentityMapIndex : UnsharedWeakKeyMapIndex
                      else
                        compare_keys_by_identity ? UnsharedStrongIdentityMapIndex : UnsharedStrongKeyMapIndex
                      end
        @index = index_class.new
      end

      def dispatch(action, *arguments)
        case action
        when :read     then read(arguments.first)
        when :getkey   then getkey(arguments.first)
        when :claim    then claim(*arguments)
        when :finish   then finish(*arguments)
        when :store    then store(*arguments)
        when :delete   then delete(arguments.first)
        when :snapshot then snapshot
        when :clear    then clear
        else raise ArgumentError, "unknown weak-map action: #{action.inspect}"
        end
      end

      private

      def read(key)
        with_entry(key) { |entry| entry ? entry.read : missing }
      end

      def getkey(key)
        with_entry(key) do |entry|
          next missing unless entry

          state = entry.read
          next state unless state.first == :ok && state[1]

          alive, stored_key = entry.lookup_key
          alive ? [:ok, stored_key].freeze : [:dead]
        end
      end

      def claim(key, ticket, create)
        with_entry(key, create:) do |entry|
          next missing unless entry

          result = entry.claim(ticket)
          @claims[ticket] = entry if result.first == :claimed
          result
        end
      end

      def finish(_key, ticket, action, value = nil)
        entry = @claims.delete(ticket)
        return [:stale].freeze unless entry

        alive, key = entry.lookup_key
        result = entry.finish(ticket, action, value)
        remove(key, entry) if result.first == :remove && alive
        result
      end

      def store(key, value, swap)
        with_entry(key, create: true) do |entry|
          state = entry.read
          next state if state.first == :busy

          present, current = state[1], state[2]
          entry.store(value)
          [:ok, swap && present ? current : nil].freeze
        end
      end

      def delete(key)
        with_entry(key) do |entry|
          next [:missing] unless entry

          result = entry.delete
          remove(key, entry) if result.first == :ok
          result
        end
      end

      def snapshot
        entries = @index.snapshot
        pairs = []
        entries.each do |entry|
          state = entry.read
          return state if state.first == :busy
          next unless state.first == :ok && state[1]

          alive, key = entry.lookup_key
          pairs << [key, state[2]].freeze if alive
        end
        @index.sweep(entries)
        [:ok, pairs.freeze].freeze
      end

      def clear
        @claims.clear
        @index.clear
        changed
        [:ok].freeze
      end

      def with_entry(key, create: false)
        @index.sweep_one
        loop do
          entry, created = @index.resolve(key, create:) do |key_reference|
            VaultWeakMapCell.new(key_reference, weak_values: @weak_values)
          end
          return yield(nil) unless entry
          changed if created

          state = yield(entry)
          if state.first == :dead || state.first == :retired
            entry.retire
            remove(key, entry)
            next
          end
          if created && state.first != :claimed && !entry.read.fetch(1, false)
            remove(key, entry)
            entry.retire
          end
          return state
        end
      end

      def missing = [:missing, @changes, @changes.value].freeze

      def remove(key, entry)
        @index.remove(key, entry)
        changed
      end

      def changed = @changes.update { |generation| generation + 1 }
    end
    private_constant :VaultWeakMapState
  end
end
