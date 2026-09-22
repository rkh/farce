# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class Vault
      class Manager
        def initialize
          @data       = ObjectSpace::WeakKeyMap.new
          @weak_maps  = ObjectSpace::WeakKeyMap.new
          @weak_atoms = ObjectSpace::WeakKeyMap.new
        end

        def run = (run_once while true)

        def move(key, _value, port)
          respond(port, [true, @data.delete(key)].freeze, move: true)
        end

        def copy(key, _value, port)
          respond(port, [true, @data[key]].freeze, move: false)
        end

        def same_value(key, value, port)
          right, identity, right_stored = value
          left   = @data[key]
          right  = @data[right] if right_stored
          result = identity ?
            BasicObject.instance_method(:equal?).bind_call(left, right) :
            !!(left == right) # rubocop:disable Style/DoubleNegation
          respond(port, [true, result].freeze)
        end

        def delete(key, _value, port)
          @data.delete(key)
          respond(port, true)
        end

        def set(key, value, port)
          @data[key] = value
          respond(port, true)
        end

        def weak_atom(key, value, port)
          command, *arguments = value
          if command == :create
            @weak_atoms[key] = VaultWeakAtomSlot.new(*arguments)
            return respond(port, [true, nil].freeze)
          end
          slot = @weak_atoms[key]
          raise ArgumentError, "unknown weak atom" unless slot
          result = case command
                   when :read then slot.value
                   when :store then slot.store(arguments.first)
                   else raise ArgumentError, "unknown weak-atom action: #{command.inspect}"
                   end
          respond(port, [true, result].freeze)
        end

        def weak_map(key, value, port)
          command, *arguments = value
          if command == :create
            options = arguments.first
            @weak_maps[key] = VaultWeakMapState.new(**options)
            return respond(port, [true, [:ok].freeze].freeze)
          end
          map = @weak_maps[key]
          raise ArgumentError, "unknown weak map" unless map
          respond(port, [true, map.dispatch(command, *arguments)].freeze)
        end

        private

        def run_once
          request = receive_request
          action, key, value, port = request
          # Ractor.receive can retain its last result while waiting for another
          # message. Clear the copied request shell before it becomes idle.
          request.clear unless request.frozen?
          public_send(action, key, value, port)
        rescue StandardError => e
          begin
            respond_error(port, e)
          rescue StandardError => e
            warn "Vault error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
          end
        end

        def respond_error(port, error)
          payload = if port.is_a?(Atom)
                      [error.class, error.message.freeze, error.backtrace&.map(&:freeze)&.freeze].freeze
                    else
                      error
                    end
          respond(port, [false, payload].freeze)
        rescue StandardError
          # Preserve diagnostics when the exception or its cause cannot cross Ractors.
          remote = ::Ractor::RemoteError.new("#{error.class}: #{error.message}")
          remote.instance_variable_set(:@ractor, ::Ractor.current)
          remote.set_backtrace(error.backtrace&.map { |line| String.new(line) })
          respond(port, ::Ractor.make_shareable([false, remote].freeze))
        end
      end

      def move_in(key, value) = execute(:set, key, value, move: true)
      def copy_in(key, value) = execute(:set, key, value, move: false)
      def move_out(key)       = execute(:move, key)
      def copy_out(key)       = execute(:copy, key)

      def same_value?(left, right, identity: false, right_stored: true)
        execute(:same_value, left, [right, identity, right_stored].freeze)
      end

      def delete(key) = execute(:delete, key)

      def weak_map(key, action, *) = shared_request(:weak_map, key, action, *)
      def weak_atom(key, action, *) = shared_request(:weak_atom, key, action, *)

      private

      def shared_request(kind, key, action, *arguments)
        raise ThreadError, "deadlock; recursive access from the Vault Ractor" if ::Ractor.current.equal?(@ractor)
        raise Ractor::IsolationError, "key must be shareable" unless ::Ractor.shareable?(key)

        pending = Object.new.freeze
        reply = Atom.new(pending, compare_by_identity: true)
        @ractor.send([kind, key, [action, *arguments].freeze, reply])
        success, payload = reply.wait_until_changed(pending)
        return payload if success

        raise payload if payload.is_a?(Exception)

        error_class, message, backtrace = payload
        error_class = RuntimeError unless error_class.is_a?(Class) && error_class <= StandardError
        error = error_class.allocate
        Exception.instance_method(:initialize).bind_call(error, message)
        error.set_backtrace(backtrace) if backtrace
        raise error
      end
    end
  end
end
