# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/portable_transaction"

module Farce
  # A transaction groups multiple changes to Farce objects into a single atomic attempt.
  #
  # These changes either all succeed together when the transaction is committed
  # or are all discarded if the transaction fails.
  #
  # Transaction attempts are isolated and can be retried safely.
  #
  # You must therefore make sure that any side-effects not going through transaction wrappers
  # are either completely avoided, or at least made idempotent.
  #
  # ```ruby
  # account1 = Farce::Atom.new(10)
  # account2 = Farce::Atom.new(20)
  #
  # # Wire 10 from account1 to account2
  # Farce.transaction do |tx|
  #   raise "insufficient funds" unless tx[account1].value >= 10
  #   tx[account1].update { it - 10 }
  #   tx[account2].update { it + 10 }
  # end
  # ```
  #
  # Transactions can mix different types and variants, and are therefore ideal for coordinating complex, coordinated
  # changes affecting data within multiple scopes.
  #
  # ## Supported objects
  #
  # Out of the box, transactions support instances of the following classes:
  class Transaction
    include Internal::Autoloads
    include Unshareable

    # Raised when a wrapper is used outside its transaction attempt.
    ClosedError    = Class.new(StandardError)
    # Raised when another Fiber uses a transaction.
    OwnershipError = Class.new(StandardError)
    Aborted        = Class.new(StandardError)
    private_constant :Aborted, :MapOperations, :SetOperations

    # @note This method must be called from the main Ractor, and the block must be convertible to a shareable proc.
    #
    # Registers a wrapper for a custom class, allowing them to be used within transactions.
    #
    # @example
    #   Account = Struct.new(:balance) do
    #     def withdraw(amount) = balance.value -= amount
    #   end
    #
    #   Farce::Transaction.define(Account) do |account, tx|
    #     account.class.new(tx[account.balance])
    #   end
    #
    #   account = Account.new(Farce::Atom.new(10))
    #   Farce.transaction { |tx| tx[account].withdraw(3) }
    #   account.balance.value # => 7
    #
    # @param klass [Class] the class to wrap
    # @yieldparam object [Object] the participant
    # @yieldparam transaction [Transaction] the current attempt
    # @yieldreturn [Object] the transaction wrapper
    def self.define(klass, &)
      raise LocalJumpError, "no block given" unless block_given?
      definition = Internal.prepare_method_definition(&)
      REGISTER.define(klass) { define_method(:call, definition) }
    end

    # Default factory for participants without a registered wrapper definition.
    # @api private
    class Factory
      include Shareable::Immutable

      # Ask a participant's hook to build a wrapper for the supplied attempt.
      # @param object [#transaction_wrapper] the participant to wrap
      # @param transaction [Transaction] the current attempt
      # @return [Object] the wrapper returned by the participant's hook
      def call(object, transaction)
        raise TypeError, "#{object.class} does not support transactions" unless object.respond_to?(:transaction_wrapper)
        object.transaction_wrapper(transaction)
      end
    end

    REGISTER = ClassMirror.new(Factory) { |mapped, _source| mapped.new }
    private_constant :Factory, :REGISTER

    # @overload run(*objects, retries: 100, backoff_after: 10)
    #   Creates and runs a new transaction attempt.
    #   Automatically retries failed attempts up to the specified number of retries.
    #   Starts backing off after the specified number of attempts.
    #   @param objects [Array] list of objects to enroll in the transaction
    #   @param retries [Integer] maximum additional attempts
    #   @param backoff_after [Integer] number of attempts before starting to back off
    #   @return [Boolean] whether the transaction committed successfully
    #   @see Farce.transaction
    def self.run(*, retries: 100, backoff_after: 10, &) # rubocop:disable Naming/PredicateMethod
      raise LocalJumpError, "no block given" unless block_given?
      raise ArgumentError, "retries must be a non-negative Integer" unless Integer === retries && retries >= 0
      unless Integer === backoff_after && backoff_after >= 0
        raise ArgumentError, "backoff_after must be a non-negative Integer"
      end

      attempt = 0

      while attempt <= retries
        if attempt > backoff_after
          delay = (attempt - backoff_after) * 0.01
          scheduler = Fiber.scheduler if Fiber.respond_to?(:scheduler) && !Fiber.current.blocking?
          scheduler ? scheduler.kernel_sleep(delay) : sleep(delay)
        end

        transaction = new
        return true if transaction.run(*, &)
        return false unless transaction.retryable?

        attempt += 1
      end

      false
    end

    # Create an unused attempt bound to the current Fiber.
    # Call {#run} once to enroll participants and stage writes. Use {.run} when
    # failed comparisons or conflicts should create and run fresh attempts.
    def initialize
      @owner     = Fiber.current
      @state     = :new
      @failed    = @aborted = false
      @retryable = true
      @wrappers  = {}.compare_by_identity
      @entries   = {}.compare_by_identity
      @guards    = {}.compare_by_identity
      super
    end

    # Report the attempt's lifecycle state.
    # @return [Symbol] :new before run, :active during the block, then :committed or :failed
    attr_reader :state

    # Whether abort! was called during this attempt.
    # @return [Boolean]
    def aborted? = @aborted

    # Whether .run may retry this attempt after a failed commit or comparison.
    # Explicit aborts, wrapper exceptions, and fail!(retryable: false) disable retries.
    # @return [Boolean]
    def retryable? = @retryable && !@aborted

    # Execute this attempt once. Use {.run} for automatic retries.
    #
    # The block stages work through {#[]}. After it returns, commit validates
    # all enrolled snapshots and publishes their staged writes together.
    # Cancellation during commit is deferred until publication finishes. Once
    # committed, an interruption does not undo the changes.
    #
    # @param objects [Array] the objects to enroll in this transaction attempt
    # @yield [transaction, *objects] the current transaction and the enrolled objects
    # @yieldparam transaction [Transaction] this active attempt
    # @yieldparam objects [Array] the enrolled objects
    # @return [Boolean] whether the changes committed
    # @raise [ClosedError] if this attempt has already run
    # @raise [OwnershipError] if called from a different Fiber
    def run(*objects)
      started = false
      raise LocalJumpError, "no block given" unless block_given?
      check_owner!
      raise ClosedError, "transaction has already run" unless @state == :new

      @state  = :active
      started = true

      objects.map! { self[it] }
      yield self, *objects

      check_open!

      Thread.handle_interrupt(Internal::INTERRUPT_MASK) do
        entries   = @entries.values
        committed = !@failed && Internal.commit_transaction(entries, @guards.values)
        @state    = committed ? :committed : :failed
        Internal.notify_transaction(entries) if committed && Internal.respond_to?(:notify_transaction)
        committed
      end
    rescue Aborted
      false
    ensure
      @state = :failed if started && @state == :active
    end

    # Includes an object in this transaction and returns a transaction-aware version of it.
    # Read from and write to the returned object, so the transaction can keep track of inputs and changes.
    #
    # @param object [Object] the participant or a wrapper from this attempt
    # @return [Object] a wrapper valid only during this attempt
    # @raise [TypeError] if the participant is unsupported or belongs to another attempt
    def [](object)
      check_open!
      @wrappers.fetch(object) do
        @wrappers[object] = REGISTER[object.class].call(object, self)
      end
    rescue Exception # rubocop:disable Lint/RescueException -- cancellation must poison the attempt too
      if @state == :active && @owner.equal?(Fiber.current)
        @failed = true
        @retryable = false
      end
      raise
    end

    # Stop the transaction block and discard all staged writes without retrying.
    # The surrounding run call returns false. No writes to participants are published.
    #
    # @example
    #   balance = Farce::Atom.new(100)
    #
    #   Farce.transaction do |tx|
    #     tx.abort! if tx[balance] < 100
    #     tx[balance].value -= 100
    #   end
    # @return [void]
    def abort!
      check_open!
      @failed = @aborted = true
      raise Aborted, "transaction aborted"
    end

    # Mark a failed condition, even if the caller ignores its return value.
    #
    # The block may continue, but commit will discard its staged writes.
    # Custom wrappers can use this for their own conditional operations.
    #
    # Wrapper operations call this automatically when they raise. If you rescue
    # an error before a wrapper is called, such as an argument computation error,
    # call `fail!(retryable: false)` to prevent earlier writes from committing.
    #
    # @param retryable [Boolean] whether .run may repeat the block for this failure
    # @return [false]
    def fail!(retryable: true) # rubocop:disable Naming/PredicateMethod
      check_open!
      @failed = true
      @retryable &&= retryable
      false
    end

    # Check lifetime and Fiber ownership before a wrapper accesses staged data.
    # @raise [ClosedError] if the attempt is not active
    # @raise [OwnershipError] if called from a different Fiber
    # @api private
    def check_open!
      check_owner!
      raise ClosedError, "transaction attempt is closed" unless @state == :active
    end

    # Capture a backend's snapshot once and reuse it across wrappers.
    #
    # Backends that expose transaction_source share enrollment with that source,
    # so wrappers of the same storage cannot stage conflicting independent copies.
    #
    # @param backend [Object] storage providing a snapshot or transaction_source
    # @return [#working] the enrolled entry containing this attempt's staged storage
    # @api private
    def enlist(backend)
      check_open!
      source = backend.respond_to?(:transaction_source) ? backend.transaction_source : backend
      @entries.fetch(source) do
        unless source.respond_to?(:transaction_snapshot)
          raise TypeError, "#{source.class} does not support transactions"
        end
        @entries[source] = source.transaction_snapshot
      end
    end

    # Include a Local participant's shared freeze flag in commit validation.
    # Its scoped backend alone cannot reveal that another scope froze the handle.
    #
    # @param object [Object] the participant being written
    # @api private
    def guard(object)
      return unless Local::Scoped === object
      @guards[object] = object.instance_variable_get(:@farce_freeze_state)
    end

    private

    def check_owner!
      raise OwnershipError, "transaction belongs to another Fiber" unless @owner.equal?(Fiber.current)
    end
  end
end
