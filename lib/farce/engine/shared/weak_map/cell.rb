# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/weak_map/reference"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # The common cell holds its value directly. The index supplies key ownership.
    # A WeakKeyMap index owns this cell and controls its collection lifetime.
    class UnsharedWeakMapCell < UnsharedWeakMapLock
      attr_reader :token

      def initialize(key_reference)
        super()
        @token = Object.new
        @key = key_reference
        @value = nil
        @present = @retired = false
        @changes = nil
      end

      def lookup_key
        @mutex.synchronize do
          return [false, nil] if @retired
          alive, key = @key.read
          return [false, nil] unless alive
          [@reserved || !@present || read_value.first, key]
        end
      end

      def state
        @mutex.synchronize do
          return [:retired, false, nil] if @retired
          return [:dead, false, nil] unless @key.read.first
          return [:ok, false, nil] unless @present
          alive, value = read_value
          [alive ? :ok : :dead, alive, value]
        end
      end

      def present? = @mutex.synchronize { @present }
      def retired? = @mutex.synchronize { @retired }

      def store(value)
        @mutex.synchronize do
          return false if @retired || !@key.read.first
          write_value(value)
          @present = true
          @changes&.broadcast
          true
        end
      end

      def retire = retire_state(force: true).first
      def retire_if_dead = retire_state(force: false)

      def change_generation
        @mutex.synchronize { (@changes ||= Signal.new).generation }
      end

      def wait_for_change?(observed, deadline)
        timeout = deadline - Clock.now if deadline
        return false if timeout && !timeout.positive?
        !!@changes.wait(observed, timeout:) { false }
      end

      private

      def unavailable? = @retired
      def read_value = [true, @value]
      def write_value(value) = @value = value

      def retire_state(force:)
        @mutex.synchronize do
          return [false, false, nil] if @retired || (!force && @reserved)
          alive, key = @key.read
          return [false, false, nil] if !force && alive && (!@present || read_value.first)
          @retired = true
          @present = false
          @key = @value = nil
          @changes&.broadcast
          @signal&.broadcast
          [true, alive, key]
        end
      end
    end
    private_constant :UnsharedWeakMapCell

    class UnsharedWeakValueMapCell < UnsharedWeakMapCell
      private

      def read_value = @value.read
      def write_value(value) = @value = UnsharedWeakMapWeakReference.for(value)
    end
    private_constant :UnsharedWeakValueMapCell
  end
end
