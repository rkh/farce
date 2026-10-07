# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Fallback for Ruby implementations supporting Ractor but not Ractor::Port (CRuby 3.x)
    class Port
      include MarshalSupport::Reject
      include Freeze::Unfreezable

      class QueueReader
        include Freeze::Unfreezable

        FROM_RACTOR = Object.new.freeze

        def initialize
          @queue    = Queue.new(capacity: nil)
          @atom     = Atom.new
          @selector = Atom.new
          Freeze.publish(self)
        end

        def send(message, move: false)
          return @queue.push(message) if ::Ractor.shareable?(message)
          ractor = @atom.store_if_absent { ::Ractor.new { loop { ::Ractor.yield(::Ractor.receive) } } }
          ractor.send(message, move:)
          @queue.push(FROM_RACTOR)
        rescue ClosedQueueError
          raise ::Ractor::ClosedError, "The port was already closed"
        ensure
          wake_selector
        end

        def closed? = @queue.closed?

        def close
          @queue.close
          wake_selector
        end

        # Senders may be in another Ractor. Publish only the selectable control
        # endpoint and shared wake flag, leaving requests and replies local.
        def selector_watch(control, wakeup) = @selector.value = [control, wakeup].freeze

        def selector_poll
          # The empty-queue callback distinguishes no message from a nil payload.
          result = @queue.try_pop { return }
          result = @atom.value.take if FROM_RACTOR.equal?(result)
          yield result
        rescue ClosedQueueError
          raise ::Ractor::ClosedError, "The port was already closed"
        end

        def wake_selector
          return unless target = @selector.value
          control, wakeup = target
          Thread.handle_interrupt(INTERRUPT_MASK) do
            control.send(nil) if wakeup.compare_and_set(false, true)
          end
        rescue ::Ractor::ClosedError
          nil
        end

        def receive(timeout: nil)
          result = @queue.pop(timeout:)
          return result unless FROM_RACTOR.equal?(result)
          @atom.value.take
        rescue ClosedQueueError
          raise ::Ractor::ClosedError, "The port was already closed"
        end
      end

      class RactorReader
        include Freeze::Unfreezable

        PATTERN = /\A#<Ractor:#(?<id>\d+) (?:.+ )?(?<status>\w+)>\z/

        def self.info(ractor, key)
          raise "unexpected Ractor#inspect format: #{ractor.inspect}" unless match = PATTERN.match(ractor.inspect)
          match[key]
        end

        def self.status(ractor) = info(ractor, :status)
        def self.id(ractor)     = info(ractor, :id)

        def initialize(ractor)
          @closed = Atom.new(false)
          @ractor = ractor
          Freeze.publish(self)
        end

        def receive(timeout: nil)
          return ::Ractor.receive if timeout.nil?
          RactorSelector.current.ractor_receive(::Ractor.current, timeout:)
        end

        def selector_source = ::Ractor.current

        def closed?   = @closed.value
        def close     = @closed.value = true
        def send(...) = @ractor.send(...)
      end

      private_constant :QueueReader, :RactorReader

      def self.new(source = UNDEFINED)
        case source
        when UNDEFINED then super(QueueReader.new)
        when ::Ractor  then super(RactorReader.new(source))
        when Port      then source
        else raise ArgumentError, "wrong number of arguments (given 1, expected 0)"
        end
      end

      def initialize(reader)
        @owner  = ::Ractor.current
        @reader = reader
        Freeze.publish(self)
      end

      def ==(other) = other.is_a?(Port) && @reader == other.reader

      def closed? = @reader.closed? || RactorReader.status(@owner) == "terminated"

      def close
        check_owner!
        @reader.close
        self
      end

      def send(message, move: false)
        raise ::Ractor::ClosedError, "The port was already closed" if closed?
        @reader.send(message, move:)
        self
      end

      alias << send

      def receive(timeout: nil)
        check_owner!
        raise ::Ractor::ClosedError, "The port was already closed" if @reader.closed?
        if selector = RactorSelector.for_call(self)
          selector.ractor_receive(self, timeout:)
        else
          @reader.receive(timeout:)
        end
      end

      def selector_source
        check_owner!
        @reader.selector_source if @reader.is_a?(RactorReader)
      end

      def selector_watch(...) = @reader.selector_watch(...)
      def selector_poll(&) = @reader.selector_poll(&)

      def inspect
        class_name = instance_of?(Port) ? "Farce::Ractor::Port" : self.class.name
        "#<#{class_name} to:##{RactorReader.id(@owner)} id:#{object_id}>"
      rescue StandardError
        super
      end

      alias receive! receive
      private :receive!

      undef dup
      undef clone

      protected

      attr_reader :reader

      private

      def check_owner!
        return true if @owner.nil? || ::Ractor.current == @owner
        raise ::Ractor::Error, "only allowed from the creator ::Ractor of this port"
      end
    end

    BasePort = Port
  end
end
