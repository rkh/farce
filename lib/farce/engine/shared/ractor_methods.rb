# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      STORAGE  = Storage::ThreadSafe.new
      STORAGES = Storage::ThreadSafe.new

      def with_storage(key)
        key = key.to_s if key.is_a?(Symbol)
        raise TypeError, "#{key.inspect} is not a symbol nor a string" unless key.is_a?(String)
        storage = Ractor.main? ? STORAGE : STORAGES.store_if_absent(Ractor.current) { Storage::ThreadSafe.new }
        yield(storage, key)
      end

      def new(...)
        return super if is_a?(Class)
        FakeRactor::NotMain.new(...)
      end

      def current = FakeRactor.current
      def main    = FakeRactor::Main::INSTANCE

      def main?
        return true if Internal.autoload?(:FakeRactor)
        FakeRactor.current.main?
      end

      def count
        return 1 if Internal.autoload?(:FakeRactor)
        FakeRactor::GROUPS.size + 1
      end

      def [](name)                   = with_storage(name) { _1[_2] }
      def builtin?                   = false
      def main_thread                = FakeRactor.main_thread
      def make_shareable(object, **) = object
      def receive(...)               = Ractor.current.receive(...)

      def shareable?(object)
        unless Kernel === object
          begin
            return object.__send__(:ractor_shareable?)
          rescue NoMethodError => e
            raise unless e.name == :ractor_shareable?
            return true
          end
        end

        object.respond_to?(:ractor_shareable?) ? object.ractor_shareable? : true
      end

      def shareable_lambda(**, &)    = Farce.rebind(lambda: true, **, &)
      def shareable_proc(**, &)      = Farce.rebind(**, &)
      def shim?                      = true
      def store_if_absent(name, &)   = with_storage(name) { _1.store_if_absent(_2, &) }
      def threads                    = FakeRactor.threads

      def []=(name, value)
        with_storage(name) { _1[_2] = value }
      end

      def select(...)
        raise "TODO: not implemented"
      end

      alias recv receive
    end
  end
end
