# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group concurrent-ruby Integration
require "farce"                              unless defined?(Farce::Abstract)
require "concurrent/map"                     unless defined?(Concurrent::Map)
require "concurrent/tvar"                    unless defined?(Concurrent::TVar)
require "concurrent/atomic/atomic_reference" unless defined?(Concurrent::AtomicReference)
require "concurrent/atomic/atomic_fixnum"    unless defined?(Concurrent::AtomicFixnum)
require "concurrent/atomic/atomic_boolean"   unless defined?(Concurrent::AtomicBoolean)
require "concurrent/atomic/event"            unless defined?(Concurrent::Event)
require "concurrent/atomic/count_down_latch" unless defined?(Concurrent::CountDownLatch)

module Farce
  module Integrations
    # @api private
    module Concurrent
      # Use TVar's own mutex so Concurrent.atomically and Farce transactions
      # exclude each other throughout an attempt.
      # @api private
      class Entry
        attr_reader :locks
        attr_accessor :value

        def initialize(source)
          @source = source
          @locks  = []
          @dirty  = @applied = false
          @lock   = source.unsafe_lock
          raise Internal::TransactionConflict, "TVar is locked" unless @lock.try_lock
          begin
            @value = @baseline = source.unsafe_value
          rescue Exception # rubocop:disable Lint/RescueException -- release on failed enrollment too
            @lock.unlock
            raise
          end
        end

        def working = self
        def write!  = @dirty = true
        def prepare = nil

        def valid?
          !(@dirty && @source.frozen?) && Internal::PortableTransaction.same?(@source.unsafe_value, @baseline)
        end

        def apply
          return unless @dirty
          @applied = true
          @source.unsafe_value = @value
        end

        def restore
          @source.unsafe_value = @baseline if @applied
        end

        # Object#freeze is independent of this mutex. A writable TVar cannot
        # safely hide a provisional value across another integration's commit.
        def reserve
          return unless @dirty
          raise TypeError, "writable Concurrent::TVar cannot participate in an external commit"
        end

        def notify  = nil
        def release = @lock.unlock
      end
    end
  end

  class Transaction
    # A Concurrent::TVar enrolled in a Farce transaction.
    #
    # Read and assign through this wrapper to stage changes alongside Farce
    # participants. Values retain their identity. Mutating a contained object
    # directly is a side effect and cannot be rolled back.
    #
    # Enrollment holds the TVar mutex until the attempt finishes. A busy mutex
    # fails the attempt so it can be retried. Once enrolled, access the TVar
    # through its wrapper to avoid trying to acquire its mutex again.
    #
    # ```ruby
    # balance  = Concurrent::TVar.new(10)
    # received = Farce::Atom.new(0)
    # Farce.transaction do |tx|
    #   tx[balance].value -= 3
    #   tx[received].value += 3
    # end
    # ```
    class TVar
      include Wrapper

      # Read the value staged in this attempt.
      # @return [Object] the staged value
      def value = access { @working.value }

      # Stage a replacement value without modifying the original TVar.
      # @param value [Object] the replacement value
      # @return [Object] the replacement value
      def value=(value)
        write { @working.value = value }
      end

      private

      def enlist(backend) = @transaction.enlist(backend) { |source| Integrations::Concurrent::Entry.new(source) }
    end
  end

  Transaction.define(::Concurrent::TVar) do |object, transaction|
    Farce::Transaction::TVar.new(transaction, object, object)
  end

  Internal::Converter.define(::Concurrent::Map, :Map) do |instance, value|
    value.each { instance[_1] = convert(_2) }
  end

  Farce.on_main do
    Subscription.define(::Concurrent::AtomicReference) { subscriber.value = it }
    Subscription.define(::Concurrent::AtomicFixnum) { |_| subscriber.increment }
    Subscription.define(::Concurrent::AtomicBoolean) { |_| subscriber.make_true }
    Subscription.define(::Concurrent::Event) { |_| subscriber.set }
    Subscription.define(::Concurrent::CountDownLatch) { |_| subscriber.count_down }
  end
end
