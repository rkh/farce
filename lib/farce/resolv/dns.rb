# frozen_string_literal: true
# shareable_constant_value: literal

module Farce
  module Resolv
    # Ractor-compatible DNS resolver
    class DNS < ::Resolv::DNS
      # @api private
      # Share reservations between threads in this Ractor without sharing mutable Ruby objects.
      def self.allocate_request_id(host, port)
        mutex, requests = Internal::Storage.store_if_absent(self) { [Thread::Mutex.new, {}] }
        mutex.synchronize do
          ids = (requests[[host, port]] ||= {})
          loop do
            id = random(0..65_535)
            next if ids.key?(id)
            ids[id] = true
            break id
          end
        end
      end

      # @api private
      # Release reservations when upstream Resolv closes a requester.
      def self.free_request_id(host, port, id)
        mutex, requests = Internal::Storage.store_if_absent(self) { [Thread::Mutex.new, {}] }
        mutex.synchronize do
          key = [host, port]
          if ids = requests[key]
            ids.delete(id)
            requests.delete(key) if ids.empty?
          end
        end
      end
    end
  end
end
