# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "objspace"

module Farce
  module Internal
    class RactorState
      def self.for(ractor) = RACTOR_STATES[ractor.object_id] # rubocop:disable Lint/HashCompareByIdentity

      def initialize
        @state    = Internal::Atom.new
        @lock     = Internal::Lock.new
        @monitors = Internal::Map.new(compare_by_identity: true)
        freeze
      end

      def monitor(port)
        @lock.synchronize do
          if state = @state.value
            port.send(state)
            false
          else
            @monitors[port] = true
          end
        end
      end

      def alive?          = @state.value.nil?
      def join            = @state.wait_until_non_nil
      def unmonitor(port) = @lock.synchronize { @monitors.delete(port) }

      def set(value)
        @lock.synchronize do
          @state.value = value
          @monitors.each_key { it.send(value) }
          @monitors.clear
        end
      end
    end

    RACTOR_STATES = Internal::Map.new(compare_by_identity: true)

    module RactorPatch
      def new(*, **, &callback)
        raise ArgumentError, "must be called with a block" unless callback
        callback       = Farce::Ractor.shareable_proc(&callback) unless Ractor.shareable?(callback)
        ractor         = super(callback, *, **) do |callback, *args|
          ractor_state = RACTOR_STATES[Ractor.current.object_id] = RactorState.new # rubocop:disable Lint/HashCompareByIdentity
          result       = instance_exec(*args, &callback)
          ractor_state.set(:exited)
          result
        rescue Exception => e # rubocop:disable Lint/RescueException
          ractor_state.set(:aborted)
          raise e
        end

        RACTOR_STATES.wait_until_non_nil(ractor.object_id)
        ObjectSpace.define_finalizer(ractor, proc { RACTOR_STATES.delete(it) })
        ractor
      end
    end

    ::Ractor.singleton_class.prepend(RactorPatch)
  end
end
