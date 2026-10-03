# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ractor-sharing Integration
require "farce"
require "ractor/tvar"
require "ractor/lockvar"
require "ractor/lockhash"
require "ractor/keylockhash"
require "ractor/active_object"
require "ractor/actor_hash"

module Farce
  module Integrations
    # @api private
    module RactorSharing
      # The private marker is published in the same STM commit as all TVars.
      # It distinguishes a failed STM attempt from a post-publication exception.
      class Commit
        def initialize(entries)
          @entries = entries
          @marker = ::Ractor::TVar.new(false)
        end

        def committed? = @marker.value

        def commit
          ::Ractor.atomically do
            @entries.each do |entry|
              unless Internal::PortableTransaction.same?(entry.source.value, entry.baseline)
                raise Internal::TransactionConflict, "TVar changed"
              end
            end
            # Validate the complete read set before staging any writes.
            @entries.each { it.source.value = it.value if it.dirty? } # rubocop:disable Style/CombinableLoops
            @marker.value = true
          end
        end
      end

      class Entry
        attr_reader :source, :baseline
        attr_accessor :value

        def initialize(source)
          # atomically is nestable, so it could return before actual publication.
          # Test a private slot before taking a snapshot or any Farce reservations.
          probe = ::Ractor::TVar.new(false)
          begin
            probe.value = false
          rescue ::Ractor::TransactionError
            # Expected outside STM. All publication belongs to our commit step.
          else
            raise ArgumentError, "Farce transactions with TVars cannot run inside Ractor.atomically"
          end
          @source = source
          @value = @baseline = ::Ractor.atomically { source.value }
          @dirty = false
        end

        def working = self
        def write! = @dirty = true
        def dirty? = @dirty
        def commit_group = Commit
      end
    end
  end

  class Transaction
    # A Ractor::TVar staged alongside ordinary Farce participants.
    #
    # Only the commit step enters Ractor.atomically. Conflicts retry the Farce
    # attempt. Values are made shareable when assigned, matching TVar's setter.
    # Mutating a contained object directly is a side effect of the attempt.
    #
    # Run the Farce transaction outside an enclosing Ractor.atomically block.
    # Writable Concurrent::TVar participants cannot join this commit step.
    #
    # @example Transfer between a TVar and an Atom
    #   available = Ractor::TVar.new(10)
    #   received  = Farce::Strict::Atom.new(0)
    #   Farce.transaction do |tx|
    #     tx[available].value -= 3
    #     tx[received].value += 3
    #   end
    class RactorTVar
      include Wrapper

      # @return [Object] the value staged in this attempt
      def value = access { @working.value }

      # Stage a shareable replacement.
      # @param value [Object] the replacement value
      # @return [Object] the shareable replacement
      def value=(value)
        # Can't use #write, as a TVar's Ruby facade is always frozen
        access do
          @entry.write!
          @working.value = ::Ractor.make_shareable(value)
        end
      end

      private

      def enlist(backend) = @transaction.enlist(backend) { Integrations::RactorSharing::Entry.new(it) }
    end
  end

  Transaction.define(::Ractor::TVar) do |object, transaction|
    Farce::Transaction::RactorTVar.new(transaction, object, object)
  end

  [::Ractor::TVar, ::Ractor::LockVar, ::Ractor::LockHash, ::Ractor::KeyLockHash].each do |klass|
    klass.include(Internal::Noncopyable) unless klass < Internal::Noncopyable
  end

  Walker.define(::Ractor::TVar) do |object, walker|
    walker.update(object, [object.value]) do |target, results|
      ::Ractor.atomically { target.value = results.first unless target.value.equal?(results.first) }
      target
    end
  end

  Walker.define(::Ractor::LockVar) do |object, walker|
    walker.update(object, [object.value]) do |target, results|
      target.update { |value| value.equal?(results.first) ? value : results.first }
      target
    end
  end

  Walker.define(::Ractor::LockHash) do |object, walker|
    values = object.to_h.flat_map { |key, value| [key, value] }
    walker.update(object, values, hash_keys: true, key_stride: 2) do |target, results|
      results.each_slice(2) { |key, _| walker.check_hash_key(key) }
      target.synchronize do
        values.each_slice(2).with_index do |(key, _), index|
          key_result = results[index * 2]
          target.delete(key) unless key.equal?(key_result)
        end
        results.each_slice(2) { |key, value| target[key] = value }
      end
      target
    end
  end

  Walker.define(::Ractor::KeyLockHash) do |object, walker|
    values = object.to_h.flat_map { |key, value| [key, value] }
    walker.update(object, values, hash_keys: true, key_stride: 2) do |target, results|
      results.each_slice(2) { |key, _| walker.check_hash_key(key) }
      values.each_slice(2).with_index do |(key, _), index|
        key_result = results[index * 2]
        target.delete(key) unless key.equal?(key_result)
      end
      results.each_slice(2) { |key, value| target[key] = value }
      target
    end
  end

  Walker.define(::Ractor::ActiveObject::Proxy) do |object, _walker|
    object
  end
end
