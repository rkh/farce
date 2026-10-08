# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/clock"

module Farce
  module Internal
    # Multiplex native Ractor waits on one thread in the receiving Ractor.
    # Native ports must be received in their owning Ractor. A helper thread can
    # block there while the calling fiber waits on a local reply queue. Results
    # stay in the same Ractor, without another copy or ownership transfer.
    # Cancelled deliveries are retained for the next receiver.
    class RactorSelector
      Request = Struct.new(:sources, :ready, :reply, :delivery, :yield_options)
      private_constant :Request

      # Storage owns one selector per Ractor and serializes its first construction.
      def self.current = Storage.store_if_absent(self) { new }

      # Farce APIs opt into cooperative waits even on third-party schedulers.
      # Native hooks never call this method. They only use the scheduler's opt-in getter.
      def self.for_call(source)
        return current if Fiber.scheduler && !Fiber.blocking?
        # Synchronous Farce calls only reuse the helper for sources it still handles.
        # Cancellation may have left a message here after removing it from the
        # native port. Receiving directly from that port would miss the message.
        existing = Storage[self]
        existing if existing&.routes?(source)
      end

      def initialize
        @commands     = Thread::Queue.new
        @wakeup       = Atom.new(false)
        @pending      = []
        @buffer       = {}.compare_by_identity
        @routing_lock = Thread::Mutex.new
        @routed       = {}.compare_by_identity
        @sequence     = 0
        @failure      = nil
        @closed       = @selecting = false
        @owner        = ::Ractor.current
        @control      = build_control
        @thread       = Thread.new { run }
        @thread.name  = "farce-ractor-selector"
      end

      # An idle selector does not change synchronous receive/select dispatch.
      # Active registrations keep concurrent waits on the same source coordinated.
      def routes?(source)
        return false if @routed.empty? && @buffer.empty?
        return source.any? { |entry| routes?(entry) } if source.is_a?(Array)
        source = receive_source(source)
        @routing_lock.synchronize { @routed.key?(source) || @buffer.key?(source) }
      end

      def closed? = @closed

      def close
        return if @closed && !@failure
        @closed = true
        begin
          acknowledge(:close) unless @failure
          @thread.join
        ensure
          close_control
        end
        nil
      end

      private

      # Retrieve an already-ready native result without re-entering the scheduler hook.
      def native(&)
        Fiber.blocking(&)
      end

      def duration(value)
        return if value.nil?
        raise TypeError, "cannot convert String into time interval" if value.is_a?(String)
        value = Float(value)
        raise RangeError, "timeout out of range" unless value.finite?
        raise ArgumentError, "time interval must not be negative" if value.negative?
        value
      end

      def wait(sources, timeout, options = nil)
        raise ::Ractor::IsolationError, "selector belongs to another Ractor" unless @owner == ::Ractor.current
        raise @failure if @failure
        raise IOError, "Ractor selector is closed" if @closed

        timeout  = duration(timeout)
        deadline = Clock.now + timeout if timeout
        sources  = sources.uniq

        sources.each { |source| validate_source(source) }

        originals           = {}.compare_by_identity
        registered          = false
        sources             = sources.map do |source|
          actual            = source.selector_source if fallback_port?(source)
          actual          ||= source
          originals[actual] = source
          actual
        end

        # Register before sending the request so concurrent receivers use the
        # same helper. Counts cover overlapping select calls and multiple threads.
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @routing_lock.synchronize do
            sources.each { |source| @routed[source] = @routed.fetch(source, 0) + 1 }
            registered = true
          end
        end
        # A zero timeout still needs one readiness poll. Positive deadlines
        # include time spent waiting for the helper to accept the request.
        request = Request.new(sources, timeout&.zero? ? Thread::Queue.new : nil, Thread::Queue.new)
        if options&.key?(:yield_value)
          # Ruby 3.4's outgoing yield competes with incoming sources. The request
          # itself identifies that outcome without colliding with a real source.
          request.yield_options = options
          sources << request
          originals[request] = :yield
        end
        command(:add, request)
        request.ready&.pop

        if deadline
          remaining = deadline - Clock.now
          remaining = 0 if remaining.negative?
        end

        delivery = request.reply.pop(timeout: remaining)
        if delivery
          _, source, value, error = delivery
          # A delivered error is accepted too, even though it unwinds this wait.
          accepted = true
          raise error if error
          [originals.fetch(source, source), value]
        end
      ensure
        # Finish cancellation before dropping routing ownership. The helper may
        # already have consumed a message that must be retained for another call.
        acknowledge(:cancel, request) if request && !accepted
        if registered
          @routing_lock.synchronize do
            sources.each do |source|
              next unless count = @routed[source]
              count == 1 ? @routed.delete(source) : @routed[source] = count - 1
            end
          end
        end
      end

      def command(action, payload = nil, ack = nil)
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @commands << [action, payload, ack]
          wake if @selecting
        end
      rescue ::ClosedQueueError
        # A caller may have passed the closed check before the helper stopped.
        fail_request(payload, @failure || IOError.new("Ractor selector is closed")) if action == :add
        ack << true if ack
      end

      # Coalesce command and shim-port notifications into one control message.
      # Mask interruption so setting the flag cannot leave an unsent wakeup.
      def wake
        Thread.handle_interrupt(INTERRUPT_MASK) do
          @control.send(nil) if @wakeup.compare_and_set(false, true)
        end
      end

      def acknowledge(action, payload = nil)
        return if @closed && action != :close
        ack = Thread::Queue.new
        Thread.handle_interrupt(INTERRUPT_MASK) do
          command(action, payload, ack)
          # Cleanup must finish even while the scheduler is unwinding a cancelled
          # fiber or shutting down. The helper acknowledges independently of it.
          Fiber.blocking { ack.pop }
        end
      end

      def forget(port)
        acknowledge(:forget, port) unless @closed
      end

      def run
        Internal.prepare_thread if defined?(Internal.prepare_thread)
        loop do
          # A data source may win select while a control notification is pending.
          # Consume that notification before parking or starting another select.
          if @wakeup.value
            receive_control
            @wakeup.value = false
          end
          # Park on the command queue when idle. Native select is only needed
          # while there are application sources to watch.
          first = @pending.empty? ? @commands.pop : nil
          break unless process_commands(first)
          dispatch_buffer
          sources = @pending.flat_map(&:sources).uniq
          sources.each { |source| poll(source) if fallback_port?(source) }
          dispatch_buffer
          next if @pending.empty? || !@commands.empty?
          native_sources = @pending.flat_map(&:sources).uniq.reject do |source|
            source.is_a?(Request) || fallback_port?(source)
          end
          yielding = @pending.find(&:yield_options)
          begin
            # Publish the selecting state before rechecking commands. A concurrent
            # sender then either reaches this check or wakes the native select.
            @selecting = true
            next unless @commands.empty?
            source, value = ::Ractor.select(*native_sources, @control, **(yielding&.yield_options || {}))
          ensure
            @selecting = false
          end
          source = yielding if source == :yield
          if source.equal?(@control)
            @wakeup.value = false
          else
            record(source == :receive ? @owner : source, value)
          end
        rescue ::Ractor::ClosedError
          # Isolate a closed or foreign port instead of failing unrelated waits.
          sources.each { |source| poll(source) }
        end
      rescue Exception => e # rubocop:disable Lint/RescueException -- Preserve helper failures for callers and close.
        @failure = e
        raise
      ensure
        # Stop accepting commands before draining them, including late registrations.
        @commands.close
        @closed = true
        error = @failure || IOError.new("Ractor selector stopped")
        @pending.each { |request| fail_request(request, error) }
        until @commands.empty?
          action, payload, ack = @commands.pop(true)
          fail_request(payload, error) if action == :add
          ack << true if ack
        end
        cleanup_control
      end

      def process_commands(first = nil) # rubocop:disable Naming/PredicateMethod
        while first || !@commands.empty?
          action, payload, ack = first || @commands.pop(true)
          first = nil
          case action
          when :add
            @pending << payload
            payload.sources.each do |source|
              source.selector_watch(@control, @wakeup) if fallback_port?(source)
              poll(source) if payload.ready && !@buffer.key?(source)
            end
            dispatch_buffer
            payload.ready&.push(true)
          when :cancel
            @pending.delete(payload)
            if payload.delivery && !payload.delivery[3] && !payload.delivery[1].is_a?(Request)
              # Queuing a reply does not mean the caller accepted it. Restore
              # unclaimed messages in receive order, even if cancellations arrive
              # out of order. Errors and completed outgoing yields cannot be replayed.
              source = payload.delivery[1]
              (@buffer[source] ||= []) << payload.delivery
              @buffer[source].sort_by!(&:first)
            end
          when :forget
            # Temporary monitor ports may have retained readiness notifications.
            @buffer.delete(payload)
          when :close
            @pending.each { |request| fail_request(request, IOError.new("Ractor selector is closed")) }
            @pending.clear
            ack << true
            return false
          end
          ack << true if ack
        end
        true
      end

      def poll(source)
        return if source.is_a?(Request)
        if fallback_port?(source)
          source.selector_poll { |value| record(source, value) }
        else
          # A ready control message lets select return when the source has no
          # value, providing a readiness poll on Rubies without native timeouts.
          wake
          selected, value = ::Ractor.select(source, @control)
          if selected.equal?(@control)
            @wakeup.value = false
            check_closed(source)
          else
            record(selected == :receive ? @owner : selected, value)
          end
        end
      rescue StandardError => e
        record(source, nil, e)
      end

      def record(source, value, error = nil)
        @sequence += 1
        (@buffer[source] ||= []) << [@sequence, source, value, error]
      end

      def dispatch_buffer
        @pending.dup.each do |request|
          source = request.sources.find { |candidate| @buffer.key?(candidate) }
          next unless source
          delivery = @buffer[source].shift
          @buffer.delete(source) if @buffer[source].empty?
          @pending.delete(request)
          # Keep the delivery attached until the caller accepts it or cancels.
          request.delivery = delivery
          request.reply << delivery
        end
      end

      def fail_request(request, error)
        request.reply << [nil, nil, nil, error]
        request.ready&.push(true)
      end
    end
  end
end
