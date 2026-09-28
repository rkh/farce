# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/envelope"

module Farce
  class Proxy < BasicObject
    # Creates a new register for defining wrapper methods for proxy classes.
    # @api private
    class Supervisor # :nodoc: all
      NilValue = Object.new.freeze
      Request  = Data.define(:success, :result, :args, :kwargs, :block)

      attr_reader :mode_manager, :register

      def initialize(register, scheduler, reference)
        @mode_manager = ModeManager.new(register:)
        @queue        = Strict::Queue.new(capacity: 1)
        @pending      = Strict::Map.new(compare_by_identity: true)
        @register     = register
        @scheduler    = scheduler
        @reference    = reference
      end

      def run(object)
        @owner         = Internal::ProxyOwner.current
        @wrapper_class = @register.outer_mirror[::Kernel.instance_method(:class).bind_call(object)]
        Ractor.make_shareable(self)
        @owner.register(self)
        @scheduler.schedule(mode: :local) { run!(object) }
      end

      # Sends a method to the outer wrapper, which then will most likely trigger {#dispatch},
      # which will send it over the queue to the inner wrapper.
      def send(...)
        check_owner!
        wrapper.__send__(...)
      end

      # Dispatches the method call to the inner wrapper via the queue and waits for the result.
      # Called by Wrapper::Outer#method_missing
      def dispatch(*args, **kwargs, &)
        args.map! { @mode_manager.wrap(it) }
        kwargs.transform_values! { @mode_manager.wrap(it) }

        Ractor.make_shareable(kwargs)
        Ractor.make_shareable(args)

        block   = Ractor.shareable_proc(&) if block_given?
        request = Request.new(Internal::Flag.new, Strict::Queue.new(capacity: 1), args, kwargs, block)

        begin
          @pending[request.result] = true
          # Register before checking closure so shutdown cannot miss this reply.
          check_owner!
          @queue.push(request)
          result = request.result.pop
        rescue ClosedQueueError
          raise Ractor::RemoteError, "proxy owner has stopped"
        ensure
          @pending.delete(request.result)
        end

        value = @mode_manager.unwrap(result)
        value = nil if NilValue.equal?(value)

        return value if request.success.value
        value = Ractor::RemoteError.new(value) if value.is_a?(String)
        raise value
      end

      def method_defined?(...)
        check_owner!
        wrapper.respond_to?(...)
      end

      def stop
        @queue.close
        @pending.each_key(&:close)
        @owner.unregister(self)
      end

      private

      def check_owner!
        return if @owner.alive? && !@queue.closed?
        raise Ractor::RemoteError, "proxy owner has stopped"
      end

      def wrapper
        token = @reference.value
        Internal::Storage.store_if_absent(token) { @wrapper_class.new(self) }
      end

      def deliver(request, result)
        request.result.push(result)
      rescue ClosedQueueError
        # The owner may have stopped while the target method was running.
        nil
      end

      def run!(object)
        inner_wrapper = @register.inner_mirror[::Kernel.instance_method(:class).bind_call(object)].new(object, self)
        until @queue.closed?
          @queue.seal unless @reference.alive?
          begin
            request = @queue.pop(timeout: 0.1)
          rescue ClosedQueueError
            break
          end
          next unless request
          begin
            args                  = request.args.map { @mode_manager.unwrap(it) }
            kwargs                = request.kwargs.transform_values { @mode_manager.unwrap(it) }
            result                = inner_wrapper.__send__(*args, **kwargs, &request.block)
            request.success.value = true
            result                = SELF if object.equal?(result)
            result = nil.equal?(result) ? NilValue : @mode_manager.wrap(result)
          rescue Exception => e # rubocop:disable Lint/RescueException
            request.success.value = false
            begin
              result = @mode_manager.wrap(e)
            rescue StandardError
              result = -"#{e.class}: #{e.message}"
            end
          end
          deliver(request, result)
        end
      ensure
        stop
      end
    end

    private_constant :Supervisor
  end
end
