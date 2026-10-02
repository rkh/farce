# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Transaction hooks for the JRuby and TruffleRuby map backends.
    module TransactionMapBackend
      def transaction_snapshot            = PortableTransaction.snapshot(self, :map)
      def transaction_size_snapshot(size) = PortableTransaction::MapSizeEntry.new(self, size)
      def transaction_pairs               = entries_snapshot

      # Whether no native operations, key reservations, or clear are active.
      # Commit calls this with the reservation and state mutexes already held.
      def transaction_idle?
        !@active_owner_fiber && !@active_owners && !@clearing_reservations && @reservations.empty?
      end
    end
  end
end
