# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      class Manager
        def initialize
          @data = ObjectSpace::WeakKeyMap.new
        end

        def run = (run_once while true)

        private

        def run_once
          action, key, value, port = ::Ractor.receive
          case action
          when :move   then return respond(port, [true, @data.delete(key)].freeze, move: true)
          when :copy   then return respond(port, [true, @data[key]].freeze, move: false)
          when :same_value
            right, identity, right_stored = value
            left   = @data[key]
            right  = @data[right] if right_stored
            result = identity ?
              BasicObject.instance_method(:equal?).bind_call(left, right) :
              !!(left == right) # rubocop:disable Style/DoubleNegation
            return respond(port, [true, result].freeze)
          when :delete then @data.delete(key)
          when :set    then @data[key] = value
          else warn "Unknown vault action: #{action.inspect}"
          end
          respond(port, true)
        rescue StandardError => e
          begin
            respond(port, [false, e].freeze)
          rescue StandardError => e
            warn "Vault error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
          end
        end
      end

      def initialize
        @ractor = ::Ractor.new { Manager.new.run }
        ::Ractor.make_shareable(self)
      end

      def move_in(key, value) = execute(:set, key, value, move: true)
      def copy_in(key, value) = execute(:set, key, value, move: false)
      def move_out(key)       = execute(:move, key)
      def copy_out(key)       = execute(:copy, key)

      def same_value?(left, right, identity: false, right_stored: true)
        execute(:same_value, left, [right, identity, right_stored].freeze)
      end

      def delete(key) = execute(:delete, key)
    end
  end
end
