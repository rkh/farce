# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    module PortableTransaction
      # Stop new ordered-key reservations and reject initializers already active.
      # Ordinary TreeMap operations already use this guard and participant count.
      class ReservationEntry < Entry
        def initialize(source) # rubocop:disable Lint/MissingSuper
          @source = source
          @locks = [source.instance_variable_get(:@guard)]
        end

        def prepare; end
        def apply; end
        def restore; end
        def notify; end

        def valid?
          participants = @source.instance_variable_get(:@participants)
          participants = participants.value unless Integer === participants
          participants.zero?
        end
      end

      # Keep the state object and lock stable for ordinary operations already
      # waiting on them. Only replace storage under that existing lock.
      class TreeEntry < Entry
        def initialize(source, working, revision, lock, field) # rubocop:disable Lint/MissingSuper
          @source = source
          @working = working
          @state = source.instance_variable_get(:@state)
          @baseline = revision
          @locks = [lock]
          @field = field
          @dirty = @applied = false
        end

        def prepare
          state = @working.instance_variable_get(:@state)
          @replacement = @field == :tree ? state.tree : state.entries
          @next_version = @baseline + 1
        end

        def valid?
          return false if @dirty && @source.frozen?
          owner = if @field == :tree
                    @source.instance_variable_get(:@guard).instance_variable_get(:@owner)
                  else
                    @state.operation_owner
                  end
          return false if owner || @state.revision != @baseline
          @original = @field == :tree ? @state.tree : @state.entries
          true
        end

        def apply
          return unless @dirty
          @applied = true
          replace(@replacement, @next_version)
        end

        def restore
          replace(@original, @baseline) if @applied
        end

        def notify; end

        private

        def replace(storage, revision)
          if @field == :tree
            @state.tree = storage
          else
            @state.instance_variable_set(:@entries, storage)
          end
          @state.revision = revision
        end
      end
    end
  end
end
