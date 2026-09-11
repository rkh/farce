# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/jvm/types"
require "farce/engine/jvm/extension"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Java owns the lock, ordered buckets, FIFO links, and cancellation index.
    # Ruby callbacks retain Ruby comparison, identity, and notification semantics.
    class PriorityQueue
      Box = Struct.new(:value)
      INITIALIZATION_LOCK = Mutex.new
      INTERRUPT_MASK = { Exception => :never }.freeze
      JAVA_CAPACITY_MAX = (1 << 63) - 1
      COMPARATOR = JVMExtension::PriorityKey.comparator(JVMContainers.comparator do |left, right|
        JVMContainers.compare(left.value, right.value)
      end)
      SNAPSHOT = lambda do |key|
        value = JVMContainers.copy_frozen_string(key.getRubyKey.value)
        JVMExtension::PriorityKey.new(Box.new(value), false, 0.0)
      end
      IDENTITY = ->(box) { JVMContainers.identity_token(box.value).to_s }
      EQUAL = ->(stored, requested) { stored.value == requested.value }
      IDENTICAL = ->(stored, requested) { JVMContainers.identical?(stored.value, requested.value) }
      MATCH = ->(stored, requested) { requested.value === stored.value } # rubocop:disable Style/CaseEquality
      SCHEDULED = lambda do
        next false unless Fiber.respond_to?(:scheduler)
        next false if Fiber.current.respond_to?(:blocking?) && Fiber.current.blocking?

        scheduler = Fiber.current_scheduler if Fiber.respond_to?(:current_scheduler)
        scheduler ||= Fiber.scheduler
        !scheduler.nil?
      end
      private_constant :Box, :INITIALIZATION_LOCK, :INTERRUPT_MASK, :JAVA_CAPACITY_MAX,
        :COMPARATOR, :SNAPSHOT, :IDENTITY, :EQUAL, :IDENTICAL, :MATCH, :SCHEDULED

      def initialize(capacity: nil, signal: nil, track_age: false)
        check_initialization
        parsed_capacity = normalize_capacity(capacity)
        raise TypeError, "signal must respond to #broadcast" unless signal.nil? || signal.respond_to?(:broadcast)
        # A failed notification leaves storage unchanged. Defer asynchronous
        # cancellation through notification and the Java commit it announces.
        unless signal.nil?
          committer = lambda do |operation|
            Thread.handle_interrupt(INTERRUPT_MASK) do
              signal.broadcast
              operation.run
            end
          end
        end
        java_capacity = parsed_capacity ? [parsed_capacity, JAVA_CAPACITY_MAX].min : 0
        # Subclasses may override broadcast and must retain callback semantics.
        native_signal = signal if RUBY_ENGINE == "jruby" &&
          JVMContainers.identical?(JVMContainers::OBJECT_CLASS_METHOD.bind_call(signal), Signal)
        core = JVMExtension::PriorityQueue.new(COMPARATOR, SNAPSHOT, IDENTITY, EQUAL,
          IDENTICAL, MATCH, committer, SCHEDULED, java_capacity, native_signal, track_age ? true : false)
        INITIALIZATION_LOCK.synchronize do
          Thread.handle_interrupt(INTERRUPT_MASK) do
            check_initialization
            @capacity = parsed_capacity
            @core = core
            JVMContainers.freeze_object(self)
          end
        end
      end

      def push(priority, value)
        core = storage
        if Float === priority
          core.pushFloat(priority, Box.new(priority), Box.new(value))
        else
          core.push(key(priority), Box.new(value))
        end
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def pop(&fallback) = read(0, false, nil, fallback)
      def pop_last(&fallback) = read(0, true, nil, fallback)

      def pop_before(latest_priority, &fallback)
        return read(0, false, key(latest_priority), fallback) unless Float === latest_priority

        result = storage.readBefore(latest_priority, Box.new(latest_priority))
        result.nil? ? fallback&.call : result.value
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def peek(&fallback) = read(1, false, nil, fallback)
      def peek_last(&fallback) = read(1, true, nil, fallback)
      def peek_priority(&fallback) = read(2, false, nil, fallback)
      def peek_last_priority(&fallback) = read(2, true, nil, fallback)

      def delete(priority, value) = remove(priority, value, 0)
      def delete_identity(priority, value) = remove(priority, value, 1)
      def delete_match(priority, pattern) = remove(priority, pattern, 2)

      def size
        storage.size
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def empty? = size.zero?

      def capacity
        storage
        @capacity
      end

      def closed?
        storage.isClosed
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def sealed?
        storage.isSealed
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def age_tracking? = storage.isAgeTracking

      def generation = JVMContainers.nullable(storage.generation)
      def oldest_enqueued_at = JVMContainers.nullable(storage.oldestEnqueuedAt)
      def oldest_age = JVMContainers.nullable(storage.oldestAge)

      def clear
        storage.clear
        self
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def close
        storage.close
        self
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def seal
        storage.seal
        self
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def initialize_copy(_other)
        raise TypeError, "priority queues cannot be copied"
      end

      private

      def check_initialization
        raise "priority queue is already initialized" if defined?(@core)
        raise FrozenError, "can't modify frozen #{self.class}" if JVMContainers.frozen_object?(self)
      end

      def storage
        raise "priority queue is not initialized" unless defined?(@core) && @core

        @core
      end

      def key(priority)
        floating = Float === priority
        JVMExtension::PriorityKey.new(Box.new(priority), floating, floating ? priority : 0.0,
          String === priority)
      end

      def read(kind, last, cutoff, fallback)
        result = storage.read(kind, last, cutoff)
        result.nil? ? fallback&.call : result.value
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def remove(priority, value, kind)
        storage.removeValue(key(priority), Box.new(value), kind)
      rescue JVMExtension::QueueFailure => e
        raise_failure(e)
      end

      def raise_failure(error)
        klass = case error.getCode
                when 2 then ::Farce::Queue::ClosedError
                when 4 then ::Farce::Queue::SealedError
                else ThreadError
                end
        raise klass, error.getMessage
      end

      def normalize_capacity(value)
        return nil if value.nil?

        unless JVMContainers.is_a?(value, Integer)
          raise TypeError, "capacity must be an Integer or nil" unless value.respond_to?(:to_int)

          value = value.to_int
        end
        raise TypeError, "capacity must be an Integer or nil" unless JVMContainers.is_a?(value, Integer)
        raise ArgumentError, "capacity must be positive or nil" unless value.positive?

        value
      end
    end
  end
end
