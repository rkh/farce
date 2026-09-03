# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module Vault
      # class Keeper
      #   def initialize
      #     @ractor = ::Ractor.new do
      #       vault = Vault.new
      #       while true
      #         port, move, message = receive
      #         begin
      #           result = vault.public_send(*message)
      #           port.send([true, result].freeze, move:)
      #         rescue Exception => e
      #           begin
      #             port.send([false, e].freeze, move: true)
      #           rescue Exception
      #             port.send(false)
      #           end
      #         end
      #       end
      #     end
      #     ::Ractor.make_shareable(self)
      #   end

      #   def move_in(...)  = execute(true, :move_in, ...)
      #   def move_out(...) = execute(true, :move_out, ...)
      #   def copy_in(...)  = execute(false, :copy_in, ...)
      #   def copy_out(...) = execute(false, :copy_out, ...)

      #   private

      #   def execute(move, *message)
      #     port, mutex = Storage.store_if_absent(self) { [Port.new, Mutex.new] }
      #     success     = nil
      #     payload     = nil

      #     mutex.synchronize do
      #       port.send([port, move, message].freeze, move:)
      #       success, payload = port.receive
      #     end

      #     return payload if success
      #     raise payload if payload
      #     raise ::Ractor::RemoteError, "Vault keeper encountered an error"
      #   end
      # end

      # def initialize
      #   @data = ObjectSpace::WeakKeyMap.new
      # end

      # def move_in(key, value)
      #   @data[key] = value
      #   nil
      # end

      # def move_out(key) = @data.delete(key)

      # def copy_in(key, value)
      #   @data[key] = value
      #   nil
      # end

      # def copy_out(key) = @data[key]
    end
  end
end
