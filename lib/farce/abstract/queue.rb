# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A shared super class for all queues defined by Farce.
    #
    # A queue is a collection of items that can be added to and removed from in a thread-safe manner.
    # The order is typically FIFO (first-in, first-out), but other orderings may be applied on top.
    #
    # Queues have a blocking and non-blocking interface.
    #
    # @!attribute [r] capacity
    #   @abstract
    #   @return [Integer, nil] The maximum number of items the queue can hold.
    #
    # @!attribute [r] num_waiting
    #   @abstract
    #   The number of threads/fibers currently waiting on the queue. This is a momentary snapshot and may be an
    #   approximation. The number may also include threads waiting for a push to succeed, as well as threads waiting
    #   without modifying the queue.
    #   @return [Integer] Number of threads/fibers waiting on the queue.
    #
    # @!attribute [r] size
    #   @abstract
    #   @return [Integer] The current number of items in the queue.
    #
    # @!method initialize(capacity: 1024)
    #   @abstract Subclasses may add additional parameters to this method.
    #   @param capacity [Integer, nil]
    #     The maximum number of items the queue can hold.
    #     If `nil`, the queue is unbounded.
    #
    #     The default may vary for subclasses.
    #     Most notably, priority and timer queues default to `nil`.
    #
    # @!method clear
    #   @abstract
    #   Removes all items from the queue.
    #   @return [self]
    #
    # @!method close
    #   @abstract
    #   Closes the queue, preventing any further items from being added.
    #   @return [self]
    #
    # @!method closed?
    #   @abstract
    #   Checks whether the queue is closed.
    #   @return [Boolean] `true` if the queue is closed, `false` otherwise.
    #
    # @!method empty?
    #   @abstract
    #   Checks whether the queue is empty.
    #   @return [Boolean] `true` if the queue is empty, `false` otherwise.
    #
    #
    # @!method pop(non_block = false, timeout: nil)
    #   @abstract Subclasses may add additional parameters to this method.
    #   Takes an item from the queue, blocking until one is available or the timeout expires.
    #   @yield Block called if the timeout expires before an item is available.
    #   @param non_block [Boolean] whether to raise an exception when the queue is empty
    #   @param timeout [Numeric, nil]
    #     The maximum time to wait for an item to be available.
    #     If `nil`, the method will wait indefinitely.
    #     If `0`, the method will not wait at all.
    #   @raise [ThreadError] when the queue is empty and non_block is true
    #   @return [BasicObject, nil]
    #     The item taken from the queue, or the return value of the block or `nil` if the timeout expired.
    #
    # @!method push(value, non_block = false, timeout: nil)
    #   @abstract
    #     Subclasses may add additional parameters to this method.
    #     They may also restrict what types of values can be pushed onto the queue.
    #     In particular, some queues may only accept Ractor-shareable values.
    #   Pushes an item onto the queue. May block if the queue is at capacity.
    #   If the queue is unbounded, this method will never block.
    #   If a timeout is specified, the method will block until the item is added or the timeout expires.
    #   @param value [BasicObject] The item to add to the queue.
    #   @param non_block [Boolean] whether to raise an exception when the queue is full
    #   @param timeout [Numeric, nil]
    #     The maximum time to wait for the item to be added.
    #     If `nil`, the method will wait indefinitely.
    #     If `0`, the method will not wait at all.
    #   @raise [ThreadError] when the queue is full and non_block is true
    #   @return [Boolean] `true` if the item was added to the queue
    #
    # @!method try_pop
    #   @abstract Subclasses may add additional parameters to this method.
    #   Tries to take an item from the queue without blocking.
    #   If no item is available, the method will call the block if given, or return `nil` if no block is given.
    #   @yield Block called if no item is available.
    #   @return [BasicObject, nil]
    #     The item taken from the queue, or the return value of the block or `nil` if no item was available.
    #
    # @!method try_push(value)
    #   @abstract Subclasses may add additional parameters to this method.
    #   Tries to push an item onto the queue without blocking.
    #   If the queue is at capacity, the method will call the block if given, or return `false` if no block is given.
    #   @param value [BasicObject] The item to add to the queue.
    #   @yield Block called if the queue is at capacity.
    #   @return [Boolean]
    #     `true` if the item was added to the queue, `false` if the queue was at capacity and no block was given.
    #
    # @!method wait_pop(timeout: nil)
    #   @abstract Subclasses may add additional parameters to this method.
    #   Waits until an item is available to pop from the queue, or the timeout expires.
    #   Does not remove the item from the queue.
    #   Note that this method does not guarantee a subsequent call to {#pop} or {#try_pop} will succeed,
    #   as another thread may remove the item first.
    #   @param timeout [Numeric, nil]
    #     The maximum time to wait for an item to be available.
    #     If `nil`, the method will wait indefinitely.
    #     If `0`, the method will not wait at all.
    #   @return [Boolean] `true` if an item is available, `false` if the timeout expired.
    #
    # @!method wait_push(timeout: nil)
    #   @abstract Subclasses may add additional parameters to this method.
    #   Waits until there is space to push an item onto the queue, or the timeout expires.
    #   Note that this method does not guarantee a subsequent call to {#push} or {#try_push} will succeed,
    #   as another thread may add an item first.
    #   @param timeout [Numeric, nil]
    #     The maximum time to wait for space to be available.
    #     If `nil`, the method will wait indefinitely.
    #     If `0`, the method will not wait at all.
    #   @return [Boolean] `true` if space is available, `false` if the timeout expired.
    class Queue
      # Alias for {#pop} to match the interface of Ruby's Queue class.
      # @return (see #pop)
      def deq(...) = pop(...)
      alias shift deq

      # Alias for {#push} to match the interface of Ruby's Queue class.
      # @return (see #push)
      def enq(...) = push(...)
      alias << enq

      # Alias for {#size} to match the interface of Ruby's Queue class.
      # @return (see #size)
      def length = size

      # The maximum number of items the queue can hold.
      # @return [Integer, Float] the maximum number of items, or `Float::INFINITY` if the queue is unbounded.
      def max = capacity || Float::INFINITY

      # Whether the queue is at capacity.
      # @return [Boolean] `true` if the queue is at capacity, `false` otherwise.
      def full? = capacity && size >= capacity

      # @return [String] A string representation of the queue, including its class name and current state.
      def inspect = "#<#{self.class.name} #{closed? ? "closed" : inspect_info.map { "#{_1}=#{_2.inspect}" }.join(" ")}>"

      # @api private
      def pretty_print(pp)
        pp.group(1, "#<#{self.class.name}", ">") do
          if closed?
            pp.breakable " "
            pp.text "closed"
          else
            inspect_info.each do |key, value|
              pp.breakable " "
              pp.text "#{key}="
              pp.pp value
            end
          end
        end
      end

      private

      def inspect_info
        info = { size:, capacity: }.compact
        info[:num_waiting] = num_waiting if num_waiting.positive?
        info
      end
    end
  end
end
