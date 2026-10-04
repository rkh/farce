# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ractor-tmvar Integration
require "farce/integrations/ractor_sharing"
require "ractor/tmvar"

module Farce
  class Transaction
    # A Ractor::TMVar staged alongside TVars and Farce participants.
    #
    # Take, put, and swap operate on the value staged in this attempt.
    # An empty read, take, or swap, or a put into a full TMVar fails the
    # attempt. Farce.transaction retries these conditions within its retry limit.
    # The try_* methods return nil or false without failing the attempt.
    # Assigned values are made shareable, matching Ractor::TVar's setter.
    #
    # Run outside Ractor.atomically, as required by {RactorTVar}.
    # Calls from other Ractors require Ractor-safe TVar methods from ractor-sharing.
    #
    # @example Transfer from a TMVar to an Atom
    #   pending  = Ractor::TMVar.new(10)
    #   received = Farce::Strict::Atom.new(0)
    #   Farce.transaction do |tx|
    #     tx[received].value += tx[pending].take
    #   end
    class RactorTMVar < ::Ractor::TMVar
      include Wrapper

      # Bind the TMVar's underlying TVar to this attempt's shared snapshot.
      # @param transaction [Transaction] the current attempt
      # @param object [Ractor::TMVar] the participant
      def initialize(transaction, object)
        super
        # TMVar exposes no accessor for its storage. Reuse the TVar wrapper
        # so explicit enrollment of that same TVar shares all staged changes.
        compose(tvar: object.instance_variable_get(:@tvar))
      end

      Wrapper.inherit(self, :take, :try_take, :read, :try_read, :put, :try_put, :empty?, :swap)

      private

      # Translate STM retry conditions before Wrapper marks other exceptions
      # as non-retryable. No upstream STM block runs during staged operations.
      def access
        super do
          yield
        rescue ::Ractor::RetryTransaction
          raise Internal::TransactionConflict, "TMVar is empty or full"
        end
      end
    end
  end

  Transaction.define(Transaction::RactorTMVar) do |object, transaction|
    object.transaction_wrapper(transaction)
  end

  Transaction.define(::Ractor::TMVar) do |object, transaction|
    Farce::Transaction::RactorTMVar.new(transaction, object)
  end
end
