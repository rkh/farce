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

        def prepare = nil
        def apply   = nil
        def restore = nil
        def notify  = nil

        def valid?
          participants = @source.instance_variable_get(:@participants)
          participants = participants.value unless Integer === participants
          participants.zero?
        end
      end
    end
  end
end
