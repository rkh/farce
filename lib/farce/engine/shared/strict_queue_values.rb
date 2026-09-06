# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    module StrictQueueValues
      def push(value, *arguments, **options)
        check_queue_value(value)
        check_queue_value(options[:priority]) if options.key?(:priority)
        super
      end

      def try_push(value, **options, &)
        check_queue_value(value)
        check_queue_value(options[:priority]) if options.key?(:priority)
        super
      end

      private

      def check_queue_value(value)
        raise Ractor::IsolationError, "value is not Ractor-shareable" unless Ractor.shareable?(value)
      end
    end
  end
end
