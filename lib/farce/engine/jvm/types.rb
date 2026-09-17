# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Loaded only by JRuby and TruffleRuby in JVM mode. The two runtimes expose
# different Java interop namespaces, so the rest of the container code goes
# through this deliberately small bridge.

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module JVMContainers
      CLASS_ALLOCATE_METHOD               = Class.instance_method(:allocate)
      BASIC_OBJECT_EQUAL_METHOD           = BasicObject.instance_method(:equal?)
      OBJECT_CLASS_METHOD                 = Object.instance_method(:class)
      OBJECT_FREEZE_METHOD                = Object.instance_method(:freeze)
      OBJECT_FROZEN_METHOD                = Object.instance_method(:frozen?)
      OBJECT_ID_METHOD                    = BasicObject.instance_method(:__id__)
      OBJECT_INSTANCE_VARIABLES_METHOD    = Object.instance_method(:instance_variables)
      OBJECT_INSTANCE_VARIABLE_GET_METHOD = Object.instance_method(:instance_variable_get)
      OBJECT_INSTANCE_VARIABLE_SET_METHOD = Object.instance_method(:instance_variable_set)
      OBJECT_IS_A_METHOD                  = Object.instance_method(:is_a?)
      STRING_INITIALIZE_COPY_METHOD       = String.instance_method(:initialize_copy)

      if RUBY_ENGINE == "jruby"
        TreeMap       = Java::JavaUtil::TreeMap
        ArrayDeque    = Java::JavaUtil::ArrayDeque
        AtomicBoolean = Java::JavaUtilConcurrentAtomic::AtomicBoolean
        AtomicLong    = Java::JavaUtilConcurrentAtomic::AtomicLong
        Comparator    = Java::JavaUtil::Comparator
        ReentrantLock = Java::JavaUtilConcurrentLocks::ReentrantLock
      else
        TreeMap       = Java.type("java.util.TreeMap")
        ArrayDeque    = Java.type("java.util.ArrayDeque")
        AtomicBoolean = Java.type("java.util.concurrent.atomic.AtomicBoolean")
        AtomicLong    = Java.type("java.util.concurrent.atomic.AtomicLong")
        Comparator    = Java.type("java.util.Comparator")
        ReentrantLock = Java.type("java.util.concurrent.locks.ReentrantLock")
      end

      module_function

      def compare(left, right)
        comparison = left <=> right
        raise ArgumentError, "comparison failed" if comparison.nil?

        # Match rb_cmpint: comparator results only need ordering against zero;
        # they need not implement Numeric's #positive?/#negative?.
        return 1  if comparison > 0 # rubocop:disable Style/NumericPredicate
        return -1 if comparison < 0 # rubocop:disable Style/NumericPredicate

        0
      end

      # Passing a Ruby lambda through this Java method produces a concrete SAM
      # proxy. This avoids TruffleRuby choosing TreeMap's Map constructor when
      # a bare Ruby lambda could also look map-like to polyglot interop.
      def comparator(&block) = Comparator.nullsFirst(block)

      # TruffleRuby represents a Java null as Polyglot::ForeignNull. It reports
      # nil? but is not the VM's Qnil, so safe navigation still invokes methods
      # on it. Always normalize Java-returned nullable references explicitly.
      def nullable(value) = value.nil? ? nil : value

      # Call BasicObject's primitive directly so a payload cannot destabilize
      # the cancellation index by overriding #__id__.
      def identity_token(value) = OBJECT_ID_METHOD.bind_call(value)

      # Identity deletion is part of the container contract, so it must not
      # dispatch an overridable payload #equal?.
      def identical?(left, right) = BASIC_OBJECT_EQUAL_METHOD.bind_call(left, right)

      # Match rb_obj_freeze rather than dispatching to an overridable Ruby
      # method while an initialized shared container is being published.
      def freeze_object(value) = OBJECT_FREEZE_METHOD.bind_call(value)

      # Frozen local containers must remain immutable even when a subclass
      # overrides #frozen? and lies about the VM's object flag.
      def frozen_object?(value) = OBJECT_FROZEN_METHOD.bind_call(value)

      def is_a?(value, klass) = OBJECT_IS_A_METHOD.bind_call(value, klass)

      def string?(value) = is_a?(value, String)

      # Match String#-@ for ordinary Strings without dispatching an override.
      # String subclasses retain the explicit primitive snapshot path because
      # JRuby and TruffleRuby differ from CRuby around subclass #freeze hooks.
      def canonical_string(value)
        klass = OBJECT_CLASS_METHOD.bind_call(value)
        return -value if identical?(klass, String)

        copy_frozen_string(value)
      end

      # Preserve String subclasses and their comparison methods while
      # bypassing overridable #dup, #initialize_copy, #class, and #freeze.
      # This mirrors the primitive String snapshot used by native containers.
      def copy_frozen_string(value)
        klass = OBJECT_CLASS_METHOD.bind_call(value)
        copy = CLASS_ALLOCATE_METHOD.bind_call(klass)
        STRING_INITIALIZE_COPY_METHOD.bind_call(copy, value)
        OBJECT_INSTANCE_VARIABLES_METHOD.bind_call(value).each do |name|
          instance_value = OBJECT_INSTANCE_VARIABLE_GET_METHOD.bind_call(value, name)
          OBJECT_INSTANCE_VARIABLE_SET_METHOD.bind_call(copy, name, instance_value)
        end
        freeze_object(copy)
      end
    end

    class JVMOperationGuard
      def initialize(synchronized:, label:, recursive_error: nil)
        @lock            = JVMContainers::ReentrantLock.new if synchronized
        @label           = label
        @owner           = nil
        @recursive_error = recursive_error || (synchronized ? ThreadError : RuntimeError)
      end

      def synchronize(&)
        # JRuby exposes a distinct Ruby Thread wrapper to sibling Fibers on the
        # same Java thread. Normalize it before checking logical ownership so a
        # reentrant Java lock cannot admit a sibling while callbacks hold state.
        current = Internal.storage_thread(Thread.current)
        if JVMContainers.identical?(@owner, current)
          message = @recursive_error == ThreadError ? "recursive #{@label} access" :
            "container cannot be modified during comparison"
          raise @recursive_error, message
        end

        if @lock
          synchronize_locked(current, &)
        else
          begin
            @owner = current
            yield
          ensure
            Thread.handle_interrupt(INTERRUPT_MASK) { @owner = nil }
          end
        end
      end

      private

      # Querying the Java lock in ensure closes the tiny async-exception gap
      # between ReentrantLock#lock returning and Ruby recording ownership.
      # A cancellation while waiting sees false; one after acquisition always
      # releases the lock, even if it arrived before @owner was assigned.
      def synchronize_locked(current)
        acquired = @lock.tryLock
        unless acquired
          # A blocking Java lock can strand the backing thread that must run the
          # lock owner. CRuby uses a scheduler-aware native gate; JVM engines do
          # not promise that extension, so fail safely on the contended path.
          raise ThreadError, "shared JVM container contention cannot block a scheduled Fiber" if scheduled_fiber?

          @lock.lock
        end
        @owner = current
        yield
      ensure
        Thread.handle_interrupt(INTERRUPT_MASK) do
          if @lock.isHeldByCurrentThread
            @owner = nil
            @lock.unlock
          end
        end
      end

      def scheduled_fiber?
        return false unless Fiber.respond_to?(:scheduler)
        return false if Fiber.current.respond_to?(:blocking?) && Fiber.current.blocking?

        scheduler = Fiber.current_scheduler if Fiber.respond_to?(:current_scheduler)
        scheduler ||= Fiber.scheduler
        !scheduler.nil?
      end
    end
  end
end
