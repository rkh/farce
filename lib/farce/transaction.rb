# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/portable_transaction"

module Farce
  # Stage explicit container operations and publish them together.
  #
  # Only operations through transaction wrappers participate. Ordinary method
  # calls, mutations of returned objects, and external effects are not undone.
  # A failed comparison or commit conflict discards every staged write.
  # Failed wrapper operations invalidate the attempt even when rescued.
  # Independent run calls remain independent, including nested calls.
  # Exceptions before publication propagate without committing. Cancellation
  # during publication is deferred until state is committed. An interruption
  # delivered afterward does not undo a committed attempt.
  # Each retry executes the entire block again with fresh wrappers, so its
  # external effects must be repeatable.
  #
  # Atom, Map, Vector, Molecule, Set, TreeMap, and SortedSet provide {#[]}
  # wrappers. Unsupported backends and
  # ownership-moving operations raise TypeError. Wrappers expose the explicit
  # operations documented on their classes, without forwarding other methods.
  # Local participants bind to the current scope when first enrolled.
  # Transaction objects and their wrappers cannot be shared between Ractors.
  # Maps, sets, and vectors copy and validate their entire storage.
  # Unrelated key or index changes can therefore cause conflicts.
  # Molecules enroll all fields and share entries with their atom wrappers.
  # Tree maps also conflict with pending key initializers.
  # Sorted sets use Transaction::Set wrappers over ordered storage.
  # Reads see earlier staged writes, but do not provide a simultaneous snapshot
  # of all participants. Commit validates all enrolled snapshots.
  #
  # @example Commit a comparison and a map write
  #   Farce::Transaction.run(retries: 3) do |tx|
  #     tx[balance].compare_and_set(100, 90)
  #     tx[ledger][:amount] = 10
  #   end
  #
  # @example Extend the wrapper protocol
  #   def transaction_wrapper(transaction)
  #     AccountTransaction.new(transaction[balance_atom])
  #   end
  class Transaction
    include Unshareable

    # Raised when a wrapper is used outside its transaction attempt.
    ClosedError = Class.new(StandardError)
    # Raised when another Fiber uses a transaction.
    OwnershipError = Class.new(StandardError)
    Aborted = Class.new(StandardError)
    private_constant :Aborted

    # Run an attempt and optionally retry unsuccessful comparisons or conflicts.
    # An explicit abort or an exception is not retried.
    # @param retries [Integer] maximum additional attempts
    # @yieldparam transaction [Transaction] the current attempt
    # @return [Boolean] whether the changes committed
    def self.run(retries: 0)
      raise LocalJumpError, "no block given" unless block_given?
      raise ArgumentError, "retries must be a non-negative Integer" unless retries.is_a?(Integer) && retries >= 0

      attempt = 0
      loop do
        transaction = new
        return true if transaction.run { yield transaction }
        return false unless transaction.retryable? && attempt < retries

        attempt += 1
        if Fiber.respond_to?(:scheduler) && Fiber.scheduler
          Fiber.scheduler.kernel_sleep(0)
        else
          Thread.pass
        end
      end
    end

    def initialize
      @owner = Fiber.current
      @state = :new
      @failed = @aborted = false
      @retryable = true
      @wrappers = {}.compare_by_identity
      @entries = {}.compare_by_identity
      @guards = {}.compare_by_identity
      super
    end

    # The attempt is new, active, committed, or failed.
    attr_reader :state

    def aborted? = @aborted
    def retryable? = @retryable && !@aborted

    # Execute this attempt once. Use {.run} for automatic retries.
    # @return [Boolean] whether the changes committed
    def run
      started = false
      raise LocalJumpError, "no block given" unless block_given?
      check_owner!
      raise ClosedError, "transaction has already run" unless @state == :new

      @state = :active
      started = true
      yield self
      check_open!
      Thread.handle_interrupt(Internal::INTERRUPT_MASK) do
        entries = @entries.values
        committed = !@failed && Internal.commit_transaction(entries, @guards.values)
        @state = committed ? :committed : :failed
        Internal.notify_transaction(entries) if committed && Internal.respond_to?(:notify_transaction)
        committed
      end
    rescue Aborted
      false
    ensure
      @state = :failed if started && @state == :active
    end

    # Get the wrapper supplied by an object's transaction_wrapper hook.
    # A custom wrapper should compose other wrappers from this same transaction.
    # @return [Object] a wrapper valid only during this attempt
    def [](object)
      check_open!
      @wrappers.fetch(object) do
        raise TypeError, "#{object.class} does not support transactions" unless object.respond_to?(:transaction_wrapper)
        @wrappers[object] = object.transaction_wrapper(self)
      end
    rescue Exception # rubocop:disable Lint/RescueException -- cancellation must poison the attempt too
      if @state == :active && @owner.equal?(Fiber.current)
        @failed = true
        @retryable = false
      end
      raise
    end

    # Discard the attempt without retrying it.
    def abort!
      check_open!
      @failed = @aborted = true
      raise Aborted, "transaction aborted"
    end

    # Mark a failed condition even if the caller ignores its return value.
    # Custom wrappers can use this for their own conditional operations.
    # @return [false]
    def fail!(retryable: true) # rubocop:disable Naming/PredicateMethod
      check_open!
      @failed = true
      @retryable &&= retryable
      false
    end

    # @api private
    def check_open!
      check_owner!
      raise ClosedError, "transaction attempt is closed" unless @state == :active
    end

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

    # @api private
    def guard(object)
      return unless Local::Scoped === object
      @guards[object] = object.instance_variable_get(:@farce_freeze_state)
    end

    private

    def check_owner!
      raise OwnershipError, "transaction belongs to another Fiber" unless @owner.equal?(Fiber.current)
    end

    # Common wrapper mechanics. Container methods never look up ambient state.
    class Wrapper
      include Unshareable

      def initialize(transaction, object, backend = nil, manager: nil, nil_value: nil)
        @transaction = transaction
        @object = object
        @backend = backend
        @manager = manager
        @nil_value = nil_value
        @entry = transaction.enlist(backend) if backend
        @working = @entry&.working
        super()
      end

      private

      # Unsupported calls must not silently leave an otherwise committable attempt.
      # Explicit arguments avoid losing keyword calls inside JRuby forwarding methods.
      def method_missing(*arguments, **options, &)
        @transaction.fail!(retryable: false)
        super
      end

      def respond_to_missing?(...) = false

      def require_block!(present)
        return if present
        @transaction.fail!(retryable: false)
        raise LocalJumpError, "no block given"
      end

      def access
        @transaction.check_open!
        yield
      rescue Exception # rubocop:disable Lint/RescueException -- cancellation must poison the attempt too
        @transaction.fail!(retryable: false) if @transaction.state == :active
        raise
      end

      def write
        access do
          raise FrozenError, "cannot modify frozen transaction participant" if @object.frozen?
          @transaction.guard(@object)
          @entry&.write!
          yield
        end
      end

      def wrap(value, mode: nil)
        return @nil_value if value.nil? && @nil_value
        return value unless @manager
        selected = mode || @manager.mode
        if %i[move make_shareable dedup proxy].include?(selected)
          raise TypeError, "#{selected} transfers do not support transactions"
        end
        @manager.wrap(value, mode:)
      end

      def unwrap(value)
        return if @nil_value.equal?(value)
        return value unless @manager
        raise TypeError, "move envelopes do not support transactions" if Envelope::Move === value
        @manager.unwrap(value)
      end

      def matches?(current, expected, identity:)
        comparison = @manager.wrap(expected, mode: identity ? :local : :copy)
        comparison = @nil_value if expected.nil? && @nil_value
        @manager.same_value?(current, comparison, identity:)
      end

      def compared(result)
        @transaction.fail! unless result
        result
      end
    end

    # Explicit operations on one atomic reference.
    class Atom < Wrapper
      def value = access { unwrap(@working.value) }
      alias get value

      def value=(value)
        store(value)
      end

      def store(value, mode: nil)
        write { unwrap(@working.store(wrap(value, mode:))) }
      end

      def swap(value, mode: nil)
        write { unwrap(@working.swap(wrap(value, mode:))) }
      end

      def update(mode: nil)
        require_block!(block_given?)
        write { unwrap(@working.store(wrap(yield(unwrap(@working.value)), mode:))) }
      end

      def store_if_absent(mode: nil)
        require_block!(block_given?)
        write { value.nil? ? store(yield, mode:) : value }
      end

      def upsert(initial, mode: nil)
        require_block!(block_given?)
        write { store(value.nil? ? initial : yield(value), mode:) }
      end

      def compare_and_set(expected, replacement, mode: nil)
        write do
          next compared(@working.compare_and_set(expected, replacement)) unless @manager
          next compared(false) unless matches?(@working.value, expected, identity: @object.compare_by_identity?)
          @working.store(wrap(replacement, mode:))
          true
        end
      end
    end

    # Explicit operations on a concurrent map.
    class Map < Wrapper
      include Enumerable

      def [](key) = access { unwrap(@working[prepare(key)]) }

      def []=(key, value)
        store(key, value)
      end

      def get(key) = self[key]

      def fetch(key, *defaults)
        access do
          raise ArgumentError, "expected at most one default" if defaults.size > 1
          canonical = prepare(key)
          next unwrap(@working[canonical]) if @working.key?(canonical)
          next yield(key) if block_given?
          next defaults.first unless defaults.empty?
          raise KeyError.new("key not found: #{key.inspect}", receiver: @object, key:)
        end
      end

      def key?(key) = access { @working.key?(prepare(key)) }
      def size = access { @working.size }
      def empty? = size.zero?
      def keys = access { @working.keys }

      def each
        return enum_for(__method__) unless block_given?
        access { @working.each { |key, value| yield key, unwrap(value) } }
        self
      end
      alias each_pair each
      alias each_live each

      def store(key, value, mode: nil)
        write { unwrap(store_value(prepare(key), wrap(value, mode:))) }
      end

      def swap(key, value, mode: nil)
        write { unwrap(@working.swap(prepare(key), wrap(value, mode:))) }
      end

      def delete(key)
        write { unwrap(@working.delete(prepare(key))) }
      end

      def clear
        write { @working.clear }
        self
      end

      def update(key, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          unwrap(store_value(canonical, wrap(yield(unwrap(@working[canonical])), mode:)))
        end
      end

      def store_if_absent(key, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          next unwrap(@working[canonical]) if @working.key?(canonical)
          unwrap(store_value(canonical, wrap(yield, mode:)))
        end
      end

      def upsert(key, initial, mode: nil)
        require_block!(block_given?)
        write do
          canonical = prepare(key)
          value = @working.key?(canonical) ? yield(unwrap(@working[canonical])) : initial
          unwrap(store_value(canonical, wrap(value, mode:)))
        end
      end

      def compare_and_set(key, expected, replacement, mode: nil)
        write do
          canonical = prepare(key)
          next compared(@working.compare_and_set(canonical, expected, replacement)) unless @manager
          next compared(false) unless @working.key?(canonical) &&
            matches?(@working[canonical], expected, identity: @object.compare_values_by_identity?)
          store_value(canonical, wrap(replacement, mode:))
          true
        end
      end

      private

      def store_value(key, value) = @working.store(key, value)

      def prepare(key)
        return @backend.transaction_key(key) if @backend.respond_to?(:transaction_key)
        @backend.respond_to?(:normalize_external_key) ? @backend.normalize_external_key(key) : key
      end
    end

    # Ordered map operations. Comparator-equivalent keys share one slot.
    # The whole tree and its pending key reservations participate in validation.
    class TreeMap < Map
      def first_key = access { @working.first_key }
      def last_key = access { @working.last_key }
      def getkey(key) = access { @working.getkey(prepare(key)) }
      def keys = access { @working.each.map { |key, _| key }.freeze }

      def pop = write { public_pair(@working.pop) }
      def shift = write { public_pair(@working.shift) }

      def swap(key, value, mode: nil)
        write do
          canonical = prepare(key)
          previous = unwrap(@working[canonical])
          store_value(canonical, wrap(value, mode:))
          previous
        end
      end

      def compare_and_set(key, expected, replacement, mode: nil)
        write do
          canonical = prepare(key)
          next compared(false) unless @working.key?(canonical)
          current = @working[canonical]
          matches = @manager ? matches?(current, expected, identity: false) : current == expected
          next compared(false) unless matches
          store_value(canonical, wrap(replacement, mode:))
          true
        end
      end

      private

      def store_value(key, value)
        @working[key] = value
      end

      def prepare(key)
        normalizer = @object.instance_variable_get(:@key_normalizer)
        @working.prepare_key(normalizer ? normalizer.call(key) : key)
      end

      def public_pair(pair)
        [pair.first, unwrap(pair.last)] if pair
      end
    end

    # A record view whose fields compose atom wrappers in this attempt.
    # Every field is enrolled, including fields only accessed through its atom.
    class Molecule < Wrapper
      include Enumerable

      def initialize(transaction, object)
        super
        @members = object.members
        @atoms = object.each_atom.to_h.transform_values { transaction[it] }
        @fields = @members.to_h { [it, @atoms.fetch(:"#{it}_atom")] }
        @writers = @members.to_h { [:"#{it}=", @atoms.fetch(:"#{it}_atom")] }
        # Molecule permits field names that replace Enumerable methods.
        @members.each do |field|
          next unless Enumerable.method_defined?(field)
          atom = @fields.fetch(field)
          define_singleton_method(field) { access { atom.value } }
        end
      end

      def members = access { @members }
      def atoms = access { @atoms.keys.freeze }

      def each
        return enum_for(__method__) unless block_given?
        access { @members.each { yield it, @atoms.fetch(:"#{it}_atom").value } }
        self
      end
      alias each_pair each

      def each_atom
        return enum_for(__method__) unless block_given?
        access { @atoms.each { yield _1, _2 } }
        self
      end

      def each_member
        return enum_for(__method__) unless block_given?
        access { @members.each { yield it } }
        self
      end
      alias each_key each_member

      def each_value
        return enum_for(__method__) unless block_given?
        each { |_, value| yield value }
        self
      end

      private

      def method_missing(name, *arguments, **options, &block)
        return access { @atoms.fetch(name) } if @atoms.key?(name) && arguments.empty? && options.empty? && !block
        return super unless options.empty? && !block
        return access { @fields.fetch(name).value } if @fields.key?(name) && arguments.empty?
        return write { @writers.fetch(name).value = arguments.first } if @writers.key?(name) && arguments.size == 1
        super
      end

      def respond_to_missing?(name, include_private = false)
        @atoms.key?(name) || @fields.key?(name) || @writers.key?(name) || super
      end
    end

    # Explicit membership operations using the set's normalization and modes.
    # Local sets bind their backing map to the current scope.
    class Set < Wrapper
      include Enumerable

      # Reuse the participant's membership rules on a private view whose only
      # storage is a transaction map. Never expose this view to the caller.
      module View
        private

        def add_mode_value?(element, mode:)
          selected = UNDEFINED.equal?(mode) || mode.nil? ? @manager.mode : mode
          if %i[move make_shareable dedup proxy].include?(selected)
            raise TypeError, "#{selected} transfers do not support transactions"
          end
          super
        end

        def unwrap_entry(key, entry)
          raise TypeError, "move envelopes do not support transactions" if Envelope::Move === entry.payload
          super
        end
      end
      private_constant :View

      def initialize(transaction, object, map)
        super(transaction, object)
        @view = object.class.allocate
        object.instance_variables.each do |name|
          @view.instance_variable_set(name, object.instance_variable_get(name))
        end
        @view.instance_variable_set(:@map, transaction[map])
        @view.extend(View)
      end

      def include?(element) = access { @view.include?(element) }
      alias member? include?
      alias === include?

      def size = access { @view.size }
      alias length size
      def empty? = size.zero?

      def each
        return enum_for(__method__) unless block_given?
        access { @view.each { yield it } }
        self
      end

      def add(element, **)
        write { @view.add(element, **) }
        self
      end
      alias << add

      def add?(element, **)
        write { self if @view.add?(element, **) }
      end

      def delete(element)
        write { @view.delete(element) }
        self
      end

      def delete?(element)
        write { self if @view.delete?(element) }
      end

      def clear
        write { @view.clear }
        self
      end

      def merge(*enumerables)
        write { enumerables.each { |items| items.each { add(it) } } }
        self
      end

      def subtract(enumerable)
        write { enumerable.each { delete(it) } }
        self
      end
    end

    # Explicit operations on a vector.
    class Vector < Wrapper
      include Enumerable

      def [](index) = access { unwrap(@working[index]) }
      def get(index) = self[index]
      def size = access { @working.size }
      def empty? = size.zero?

      def []=(index, value)
        store(index, value)
      end

      def store(index, value, mode: nil)
        write { unwrap(@working.store(index, wrap(value, mode:))) }
      end

      def swap(index, value, mode: nil)
        write { unwrap(@working.swap(index, wrap(value, mode:))) }
      end

      def push(value, mode: nil)
        write { @working.push(wrap(value, mode:)) }
        self
      end
      alias << push

      def pop = write { unwrap(@working.pop) }

      def clear
        write { @working.clear }
        self
      end

      def each
        return enum_for(__method__) unless block_given?
        access { @working.snapshot.each { |value| yield unwrap(value) } }
        self
      end

      def update(index, mode: nil)
        require_block!(block_given?)
        write { unwrap(@working.update(index) { |value| wrap(yield(unwrap(value)), mode:) }) }
      end

      def store_if_absent(index, mode: nil)
        require_block!(block_given?)
        write { unwrap(@working.store_if_absent(index) { wrap(yield, mode:) }) }
      end

      def upsert(index, initial, mode: nil)
        require_block!(block_given?)
        write do
          unwrap(@working.upsert(index, wrap(initial, mode:)) { |value| wrap(yield(unwrap(value)), mode:) })
        end
      end

      def compare_and_set(index, expected, replacement, mode: nil)
        write do
          next compared(@working.compare_and_set(index, expected, replacement)) unless @manager
          index = Integer(index)
          next compared(false) unless index >= -@working.size && index < @working.size &&
            matches?(@working[index], expected, identity: @object.compare_by_identity?)
          @working.store(index, wrap(replacement, mode:))
          true
        end
      end
    end
  end
end
