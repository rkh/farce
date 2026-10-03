# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Own portable locks while native participants hold logical reservations.
    # Portable replacements remain hidden until the foreign commit is resolved.
    class ExternalTransaction
      def self.commit(entries, external, guards, transaction)
        groups = external.map(&:commit_group).uniq
        raise TypeError, "only one external commit integration may participate" unless groups.size == 1

        native, portable = entries.partition { NativeTransactionEntry === it }
        context = new(portable, guards, groups.first.new(external), transaction)
        flags = guards.map { it.respond_to?(:native_flag) ? it.native_flag : it }
        Internal.reserve_transaction(native, flags, context)
      end

      def initialize(entries, guards, group, transaction)
        @entries, @guards, @group, @transaction = entries, guards, group, transaction
        @acquired = []
        @attempted = nil
        @entries.each(&:prepare)
        @locks = (@entries.flat_map(&:locks) + @guards.filter_map { it.lock if it.respond_to?(:native_flag) })
          .uniq.sort_by(&:object_id)
      end

      def acquire?
        @locks.each do |lock|
          return false if lock.owned?
          @attempted = lock
          return false unless lock.try_lock
          @acquired << lock
          @attempted = nil
        end
        @guards.none?(&:value) && @entries.all?(&:valid?)
      end

      def publish_external
        @entries.each { it.reserve if it.respond_to?(:reserve) }
        @entries.each(&:apply)
        @group.commit
      end

      def committed? = @group.committed?
      def restore = @entries.reverse_each(&:restore)

      # Repeatable even if a return TracePoint interrupted a completed unlock.
      def finish
        @entries.each { it.unreserve if it.respond_to?(:unreserve) }
        [*@acquired, @attempted].compact.uniq.reverse_each do |lock|
          lock.unlock if lock.owned?
        end
        @entries.each(&:notify) if committed?
      end
    end
  end
end
