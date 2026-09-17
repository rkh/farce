# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Coordinates ownership and lifecycle for one leased resource.
    class LeaseState
      OWNED_RESOURCES         = Object.new.freeze
      SCOPE_MANAGED_RESOURCES = Object.new.freeze
      AVAILABLE               = :available
      EXPLICIT                = :explicit
      BLOCK                   = :block
      RETIRED                 = :retired
      private_constant :OWNED_RESOURCES, :SCOPE_MANAGED_RESOURCES,
        :AVAILABLE, :EXPLICIT, :BLOCK, :RETIRED

      def initialize(resource)
        validate_resource!(resource)
        initialize_state
        initialize_resource(resource)
      end

      def available? = state == AVAILABLE && !@lock.locked?
      def checked_out? = !retired? && @lock.locked?
      def owned? = !retired? && @lock.owned?
      def retired? = state == RETIRED
      def explicitly_owned? = owned? && state == EXPLICIT

      # Return the resource held by the current Fiber.
      # @raise [Farce::OwnershipError] unless the current Fiber owns the checkout
      def owned_resource
        raise OwnershipError, "the current Fiber does not own the checkout" unless @lock.owned?

        owned_resources.fetch(self)
      end

      # Replace the resource held by an explicit checkout without ending it.
      # @raise [Farce::OwnershipError] unless the current Fiber owns an explicit checkout
      def replace_owned_resource(resource)
        unless @lock.owned? && state == EXPLICIT
          raise OwnershipError, "the current Fiber does not own an explicit checkout"
        end

        validate_resource!(resource)
        owned_resources[self] = resource
        self
      end

      # Acquire explicitly and complete a caller-provided ownership handoff before interrupts resume.
      def checkout_with_handoff(timeout: nil)
        resource = nil
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            resource = wait_for_resource(timeout, EXPLICIT)
            yield resource
          end
        rescue Exception # rubocop:disable Lint/RescueException
          rollback_acquisition(resource) if resource && @lock.owned? && state == EXPLICIT
          raise
        end
        resource
      end

      # Attempt an explicit checkout and complete an ownership handoff before interrupts resume.
      def try_checkout_with_handoff
        resource = nil
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            resource = try_acquire(EXPLICIT)
            yield resource if resource
          end
        rescue Exception # rubocop:disable Lint/RescueException
          rollback_acquisition(resource) if resource && @lock.owned? && state == EXPLICIT
          raise
        end
        resource
      end

      # Mark an explicit checkout as owned by an automatic cleanup scope.
      def mark_scope_managed
        unless @lock.owned? && state == EXPLICIT
          raise OwnershipError, "the current Fiber does not own an explicit checkout"
        end

        scope_managed_resources[self] = true
        self
      end

      def scope_managed? = Storage.fiber[SCOPE_MANAGED_RESOURCES, :strong]&.key?(self) || false

      # Return a checkout through its automatic cleanup scope.
      def checkin_scope(resource)
        checkin_resource(resource, scope: true)
      end

      def checkout(timeout: nil, &block)
        return wait_for_block(timeout, block) if block

        explicit_checkout { wait_for_resource(timeout, EXPLICIT) }
      end

      def try_checkout(&block)
        if block
          outcome = try_acquire_block(block)
          return outcome.first if outcome
          return
        end

        explicit_checkout { try_acquire(EXPLICIT) }
      end

      def checkin(resource)
        checkin_resource(resource, scope: false)
      end

      def checkin_resource(resource, scope:)
        raise RetiredLeaseError, "lease has been retired" if retired?
        unless @lock.owned? && state == EXPLICIT
          raise OwnershipError, "the current Fiber does not own an explicit checkout"
        end
        raise OwnershipError, "the checkout belongs to an automatic lease scope" if scope_managed? && !scope

        validate_resource!(resource)
        Thread.handle_interrupt(INTERRUPT_MASK) do
          return_resource(resource)
          unregister_owned_resource
          release
        end
        self
      end

      def retire
        return self if retired?
        raise OwnershipError, "the current Fiber does not own the checkout" unless @lock.owned?

        Thread.handle_interrupt(INTERRUPT_MASK) do
          @state.store(RETIRED)
          unregister_owned_resource
          @owner_thread_id.store(0)
          @lock.unlock
          @signal.broadcast
        end
        self
      end

      private

      def wait_for_resource(timeout, kind)
        deadline = timeout_deadline(timeout)
        resource = nil

        loop do
          observed = @signal.generation
          resource = try_acquire(kind)
          return resource if resource

          remaining = deadline - Clock.now if deadline
          raise TimeoutError, "lease checkout timed out" if remaining && !remaining.positive?
          reject_unscheduled_fiber_wait!
          interval = wait_interval(remaining)
          changed  = Thread.handle_interrupt(Exception => :immediate) do
            @signal.wait(observed, timeout: interval)
          end
          next if changed || interval != remaining

          raise TimeoutError, "lease checkout timed out"
        end
      rescue Exception # rubocop:disable Lint/RescueException
        rollback_acquisition(resource) if resource && @lock.owned? && state == kind
        raise
      end

      def wait_for_block(timeout, block)
        deadline = timeout_deadline(timeout)

        loop do
          observed = @signal.generation
          outcome  = try_acquire_block(block)
          return outcome.first if outcome

          remaining = deadline - Clock.now if deadline
          raise TimeoutError, "lease checkout timed out" if remaining && !remaining.positive?
          reject_unscheduled_fiber_wait!
          interval = wait_interval(remaining)
          changed  = Thread.handle_interrupt(Exception => :immediate) do
            @signal.wait(observed, timeout: interval)
          end
          next if changed || interval != remaining

          raise TimeoutError, "lease checkout timed out"
        end
      end

      def checkin_block(resource)
        return if retired?
        raise OwnershipError, "the current Fiber does not own this block checkout" unless
          @lock.owned? && state == BLOCK

        Thread.handle_interrupt(INTERRUPT_MASK) do
          return_resource(resource)
          unregister_owned_resource
          release
        end
      end

      def initialize_state
        @lock            = Lock.new
        @state           = Atom.new(AVAILABLE)
        @signal          = Signal.new
        @owner_thread_id = Atom.new(0)
      end

      def state = @state.value

      def try_acquire_block(block)
        raise RetiredLeaseError, "lease has been retired" if retired?
        raise ThreadError, "deadlock; recursive lease checkout" if @lock.owned?

        acquired = false
        resource = nil
        Thread.handle_interrupt(INTERRUPT_MASK) do
          acquired = @lock.try_lock
          return unless acquired

          begin
            raise RetiredLeaseError, "lease has been retired" if retired?
            @owner_thread_id.store(Thread.current.object_id)
            @state.store(BLOCK)
            resource = take_resource
            register_owned_resource(resource)
            [Thread.handle_interrupt(Exception => :immediate) { block.call(resource) }]
          ensure
            if resource
              checkin_block(resource) if @lock.owned? && state == BLOCK
            elsif acquired
              rollback_acquisition(resource)
            end
          end
        end
      end

      def explicit_checkout
        resource = nil
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) { resource = yield }
        rescue Exception # rubocop:disable Lint/RescueException
          rollback_acquisition(resource) if resource && @lock.owned? && state == EXPLICIT
          raise
        end
        resource
      end

      def try_acquire(kind)
        raise RetiredLeaseError, "lease has been retired" if retired?
        raise ThreadError, "deadlock; recursive lease checkout" if @lock.owned?

        acquired = false
        resource = nil
        begin
          Thread.handle_interrupt(INTERRUPT_MASK) do
            acquired = @lock.try_lock
            return unless acquired

            raise RetiredLeaseError, "lease has been retired" if retired?
            @owner_thread_id.store(Thread.current.object_id)
            @state.store(kind)
            resource = take_resource
            register_owned_resource(resource)
          end
        rescue Exception # rubocop:disable Lint/RescueException
          rollback_acquisition(resource) if acquired
          raise
        end
        resource
      end

      def release
        @state.store(AVAILABLE)
        @owner_thread_id.store(0)
        @lock.unlock
        @signal.broadcast
      end

      def rollback_acquisition(resource)
        Thread.handle_interrupt(INTERRUPT_MASK) do
          return_resource(resource) if resource
          unregister_owned_resource
          @state.store(AVAILABLE) unless retired?
          @owner_thread_id.store(0)
          @lock.unlock if @lock.owned?
          @signal.broadcast
        end
      end

      def reject_unscheduled_fiber_wait!
        return unless @lock.locked? && @owner_thread_id.value == Thread.current.object_id
        return if Fiber.respond_to?(:scheduler) && Fiber.scheduler

        raise ThreadError, "deadlock; lease is owned by another unscheduled Fiber on the same thread"
      end

      def wait_interval(remaining)
        LeaseWaiting.wait_interval(remaining)
      end

      def owned_resources
        Storage.fiber.store_if_absent(OWNED_RESOURCES, mode: :strong) { {}.compare_by_identity }
      end

      def register_owned_resource(resource)
        owned_resources[self] = resource
      end

      def unregister_owned_resource
        Storage.fiber[OWNED_RESOURCES, :strong]&.delete(self)
        Storage.fiber[SCOPE_MANAGED_RESOURCES, :strong]&.delete(self)
      end

      def scope_managed_resources
        Storage.fiber.store_if_absent(SCOPE_MANAGED_RESOURCES, mode: :strong) { {}.compare_by_identity }
      end

      def timeout_deadline(timeout)
        return if timeout.nil?

        timeout = Float(timeout)
        unless timeout.finite? && !timeout.negative?
          raise ArgumentError, "timeout must be a finite, non-negative number or nil"
        end
        Clock.now + timeout
      end

      def validate_resource!(resource)
        return unless nil.equal?(resource) || true.equal?(resource) || false.equal?(resource)

        raise ArgumentError, "lease resource cannot be nil or boolean"
      end
    end
  end
end
