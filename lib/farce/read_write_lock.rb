# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable read/write lock with fiber-scheduler-aware waiting.
  #
  # Multiple execution contexts may hold the read lock concurrently. The write
  # lock is exclusive and may be acquired while the current context holds a
  # read lock. One concurrent upgrader retains its read lock continuously;
  # additional upgraders yield their read slot to avoid deadlock and restore it
  # before returning to the outer read-lock block.
  class ReadWriteLock
    include Shareable

    READER_BITS   = 30
    READER_MASK   = (1 << READER_BITS) - 1
    WRITER_BIT    = 1 << READER_BITS
    UPGRADER_BIT  = 1 << (READER_BITS + 1)
    WAITER_UNIT   = 1 << (READER_BITS + 2)
    MAX_WAITERS   = ((1 << 63) - 1) / WAITER_UNIT
    READ_DEPTH    = 0
    WRITE_DEPTH   = 1
    LOCAL_STATES  = :__farce_read_write_lock_states__
    INTERRUPTS_IMMEDIATE = { Exception => :immediate }.freeze
    INTERRUPTS_NEVER     = { Exception => :never }.freeze
    private_constant :READER_BITS, :READER_MASK, :WRITER_BIT, :UPGRADER_BIT,
      :WAITER_UNIT, :MAX_WAITERS, :READ_DEPTH, :WRITE_DEPTH, :LOCAL_STATES,
      :INTERRUPTS_IMMEDIATE, :INTERRUPTS_NEVER

    def initialize
      @state  = Internal::Vector.new([0])
      @signal = Internal::Signal.new
      super
    end

    # Runs the block while holding a shared read lock.
    #
    # @yield the block to run while holding the read lock
    # @return [Object] the block result
    def with_read_lock
      raise LocalJumpError, "no block given" unless block_given?

      local = local_state
      Thread.handle_interrupt(INTERRUPTS_NEVER) do
        global = local[READ_DEPTH].zero? && local[WRITE_DEPTH].zero?
        acquire_read_lock if global
        local[READ_DEPTH] += 1

        begin
          # Block capture allocates on every lock operation.
          # rubocop:disable-next Style/ExplicitBlockArgument
          Thread.handle_interrupt(INTERRUPTS_IMMEDIATE) { yield }
        ensure
          local[READ_DEPTH] -= 1
          release_read_lock if global
          clear_local_state(local)
        end
      end
    end

    # Runs the block while holding an exclusive write lock.
    #
    # Calling this method from inside {#with_read_lock} upgrades the read lock.
    #
    # @yield the block to run while holding the write lock
    # @return [Object] the block result
    def with_write_lock
      raise LocalJumpError, "no block given" unless block_given?

      local = local_state
      Thread.handle_interrupt(INTERRUPTS_NEVER) do
        reentrant = local[WRITE_DEPTH].positive?
        upgraded  = !reentrant && local[READ_DEPTH].positive?
        acquire_write_lock(upgraded) unless reentrant
        local[WRITE_DEPTH] += 1

        begin
          # Block capture allocates on every lock operation.
          # rubocop:disable-next Style/ExplicitBlockArgument
          Thread.handle_interrupt(INTERRUPTS_IMMEDIATE) { yield }
        ensure
          local[WRITE_DEPTH] -= 1
          unless reentrant
            upgraded ? downgrade_write_lock : release_write_lock
          end
          clear_local_state(local)
        end
      end
    end

    private

    def local_state
      states = Thread.current[LOCAL_STATES] ||= {}
      states[self] ||= [0, 0]
    end

    def clear_local_state(local)
      return unless local[READ_DEPTH].zero? && local[WRITE_DEPTH].zero?

      states = Thread.current[LOCAL_STATES]
      states.delete(self)
      Thread.current[LOCAL_STATES] = nil if states.empty?
    end

    def acquire_read_lock
      return if try_acquire_read_lock

      # Kernel.loop allocates on every acquisition.
      # rubocop:disable-next Style/InfiniteLoop
      while true
        generation = @signal.generation
        return if try_acquire_read_lock

        wait_for_change(generation)
      end
    end

    def try_acquire_read_lock
      change_state do |current|
        if readers_allowed?(current)
          raise ThreadError, "maximum reader count exceeded" if reader_count(current) == READER_MASK
          [current + 1, true]
        else
          [current, false]
        end
      end
    end

    def release_read_lock
      change_state do |current|
        raise ThreadError, "read lock is not held" if reader_count(current).zero?
        [current - 1, nil]
      end
      @signal.broadcast
    end

    def acquire_write_lock(upgrade)
      mode = upgrade ? register_upgrade : register_writer
      acquired = false

      begin
        acquired = try_acquire_write_lock(mode)
        return if acquired

        # Kernel.loop allocates on every acquisition.
        # rubocop:disable-next Style/InfiniteLoop
        while true
          generation = @signal.generation
          acquired = try_acquire_write_lock(mode)
          return if acquired

          wait_for_change(generation)
        end
      ensure
        cancel_write_request(mode) unless acquired
      end
    end

    def try_acquire_write_lock(mode)
      change_state do |current|
        retained = mode == :retained
        target_readers = retained ? 1 : 0
        available = !writer_locked?(current) && reader_count(current) == target_readers
        available &&= upgrader?(current) if retained

        if available
          replacement = current - WAITER_UNIT + WRITER_BIT
          replacement -= UPGRADER_BIT + 1 if retained
          [replacement, true]
        else
          [current, false]
        end
      end
    end

    def register_writer
      change_state { |current| [add_waiter(current), :writer] }
    end

    def register_upgrade
      mode = change_state do |current|
        raise ThreadError, "read lock is not held" if reader_count(current).zero?

        if upgrader?(current)
          [add_waiter(current) - 1, :released]
        else
          [add_waiter(current) + UPGRADER_BIT, :retained]
        end
      end
      @signal.broadcast if mode == :released
      mode
    end

    def cancel_write_request(mode)
      case mode
      when :retained
        change_state { |current| [current - WAITER_UNIT - UPGRADER_BIT, nil] }
      when :released, :writer
        change_state { |current| [current - WAITER_UNIT, nil] }
      end
      @signal.broadcast
      acquire_read_lock if mode == :released
    end

    def release_write_lock
      change_state do |current|
        raise ThreadError, "write lock is not held" unless writer_locked?(current)
        [current - WRITER_BIT, nil]
      end
      @signal.broadcast
    end

    def downgrade_write_lock
      change_state do |current|
        raise ThreadError, "write lock is not held" unless writer_locked?(current)
        [current - WRITER_BIT + 1, nil]
      end
      @signal.broadcast
    end

    def change_state
      result = nil
      @state.update(0) do |current|
        replacement, result = yield(current)
        replacement
      end
      result
    end

    def wait_for_change(generation)
      Thread.handle_interrupt(INTERRUPTS_IMMEDIATE) { @signal.wait(generation) }
    end

    def add_waiter(current)
      raise ThreadError, "maximum writer count exceeded" if waiting_writers(current) == MAX_WAITERS
      current + WAITER_UNIT
    end

    def readers_allowed?(current)
      !writer_locked?(current) && waiting_writers(current).zero?
    end

    def reader_count(current)         = current & READER_MASK
    def waiting_writers(current)      = current / WAITER_UNIT
    def writer_locked?(current)       = current.anybits?(WRITER_BIT)
    def upgrader?(current)            = current.anybits?(UPGRADER_BIT)
    def instance_variables_to_inspect = Internal::EMPTY_ARRAY
  end
end
