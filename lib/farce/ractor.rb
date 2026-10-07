# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Entry point for Ractor support.
  #
  # This is always a module, but if native Ractor support is available:
  # * It gets mixed into Ractor. This has no effect beyond another entry in the inheritance chain,
  #   so `is_a?(Farce::Ractor)` and `Farce::Ractor === ractor` work as expected.
  # * It delegates, wraps, or backports known Ractor class methods.
  #
  # If not, then this module provides a polyfill for Ractors. With the following caveats:
  # * It uses thread groups to keep track of Thread-to-Ractor associations.
  # * All objects are considered shareable.
  # * It does not monkey-patch `Thread`. This means in particular:
  #   * `Thread.list` will include all threads from all Ractors.
  #     Use {.threads Farce::Ractor.threads} instead.
  #   * `Thread.main` will return the main thread of the main Ractor, even if called from a different Ractor.
  #     Use {.main_thread Farce::Ractor.main_thread} instead.
  #
  # @!method [](key)
  #   @!scope class
  #   Retrieves a value from the current Ractor's storage by key.
  #   @param key [Symbol] The key to retrieve.
  #   @return [BasicObject, nil] The value associated with the key, or `nil` if not found.
  #
  # @!method []=(key, value)
  #   @!scope class
  #   Stores a value in the current Ractor's storage by key.
  #   @param key [Symbol] The key to store the value under.
  #   @param value [BasicObject] The value to store.
  #
  # @!method builtin?
  #   @!scope class
  #   @note This method isn't part of the official Ractor API, but is compatible with the `ractor-shim` gem.
  #   @return [Boolean] `true` if native Ractors are available, `false` otherwise.
  #
  # @!method count
  #   @!scope class
  #   Returns the number of Ractors.
  #   @return [Integer] The number of Ractors.
  #
  # @!method current
  #   @!scope class
  #   Returns the current Ractor instance.
  #   @return [Ractor] The current Ractor instance.
  #
  # @!method main
  #   @!scope class
  #   Returns the main Ractor instance.
  #   @return [Ractor] The main Ractor instance.
  #
  # @!method make_shareable(object, copy: false)
  #   @!scope class
  #   @note If native Ractors aren't available, this method simply returns the object, as all objects are shareable.
  #   Makes an object shareable between Ractors.
  #   @param object [BasicObject] The object to make shareable.
  #   @param copy [Boolean] Whether to create a copy of the object.
  #   @return [BasicObject] The shareable object.
  #
  # @!method main?
  #   @!scope class
  #   Checks if the current Ractor is the main Ractor.
  #   @return [Boolean] `true` if the current Ractor is the main Ractor, `false` otherwise.
  #
  # @!method main_thread
  #   @!scope class
  #   @note This method is not part of the official Ractor API, but is a replacement for a Ractor-unaware `Thread.main`.
  #   Returns the main thread of the current Ractor.
  #   @return [Thread] The main thread of the current Ractor.
  #
  # @!method new(*args, name: nil)
  #   @!scope class
  #   Creates a new Ractor instance.
  #   @param args [Array] The arguments to pass to the Ractor's block. Will be copied if not {.shareable? shareable}.
  #   @param name [String, nil] The name of the Ractor, or `nil` for no name.
  #   @yield [*args] The block to execute in the new Ractor.
  #   @yieldparam args [Array] The arguments passed to the Ractor.
  #   @yieldreturn [BasicObject] The {#value value} returned by the Ractor's block.
  #   @yieldreceiver [Ractor] The new Ractor instance.
  #   @return [Ractor] The new Ractor instance.
  #
  # @!method receive(timeout: nil)
  #   @!scope class
  #   Receives a message on the current Ractor's {#default_port default port}.
  #   @param timeout [Numeric, nil] The timeout in seconds, or `nil` for no timeout.
  #   @return [BasicObject, nil] The received message, or `nil` if the timeout has been reached.
  #
  # @!method select(*ractors_or_ports, timeout: nil)
  #   @!scope class
  #   Blocks the current Thread until one of the given Ractors or Ports produces a value, or until the timeout
  #   has been reached.
  #
  #   Returns an array containing the Ractor or Port that produced the value, and the value itself.
  #   Or `nil` if the timeout has been reached.
  #
  #   @param ractors_or_ports [Array<Ractor, Farce::Abstract::Port>] The Ractors or Ports to select from.
  #   @param timeout [Numeric, nil] The timeout in seconds, or `nil` for no timeout.
  #   @return [Array(Object, BasicObject), nil]
  #     An array containing the Ractor or Port that produced the value, and the value itself,
  #     or `nil` if the timeout has been reached.
  #
  # @!method shareable?(object)
  #   @!scope class
  #   @note If native Ractors aren't available, this method always returns `true`, as all objects are shareable.
  #   Checks if an object is shareable between Ractors.
  #   @param object [BasicObject] The object to check.
  #   @return [Boolean] `true` if the object is shareable, `false` otherwise.
  #
  # @!method shareable_lambda(self: nil)
  #   @!scope class
  #   {Farce.rebind Binds} a lambda to the given `self` and {.make_shareable makes it shareable} between Ractors.
  #   @yield The block to convert into a shareable lambda.
  #   @yieldreceiver [BasicObject] The object passed as `self` (or `nil`)
  #   @param self [BasicObject] The object to bind as `self`.
  #   @return [Proc] The shareable lambda.
  #   @see .shareable_proc
  #
  # @!method shareable_proc(self: nil)
  #   @!scope class
  #   {Farce.rebind Binds} a proc to the given `self` and {.make_shareable makes it shareable} between Ractors.
  #   @yield The block to convert into a shareable proc.
  #   @yieldreceiver [BasicObject] The object passed as `self` (or `nil`)
  #   @param self [BasicObject] The object to bind as `self`.
  #   @return [Proc] The shareable proc.
  #   @see .shareable_lambda
  #
  # @!method shim?
  #   @!scope class
  #   @note This method isn't part of the official Ractor API, but is compatible with the `ractor-shim` gem.
  #   @return [Boolean] `false` if native Ractors are available, `true` otherwise.
  #
  # @!method store_if_absent(key)
  #   @!scope class
  #   Stores a value in the current Ractor's storage by key if it is not already present. This method is thread-safe.
  #   @param key [Symbol] The key to store the value under.
  #   @yield Block that computes the value to store if the key is absent.
  #   @yieldreturn [BasicObject] The value to store if the key is absent.
  #   @return [BasicObject] The existing or newly stored value.
  #
  # @!method threads
  #   @!scope class
  #   @note This method isn't part of the official Ractor API, but is a replacement for a Ractor-unaware `Thread.list`.
  #   Returns the list of threads in the current Ractor.
  #   @return [Array<Thread>] The list of threads in the current Ractor.
  #
  # @!method default_port
  #   @return [Ractor::Port] The default port for the Ractor.
  #
  # @!method join
  #   Blocks the current Thread until the Ractor has terminated.
  #   @return [self]
  #
  # @!method main?
  #   @return [Boolean] `true` if the Ractor is the main Ractor
  #
  # @!method monitor(port)
  #   Monitors the given port for termination of the Ractor. If the Ractor is already terminated, the port will receive
  #   the Ractor's status immediately. The port will receive wither `:exited` or `:aborted` depending on whether the
  #   Ractor terminated normally or with an unhandled exception.
  #   @ruby CRuby 4.0+, JRuby, TruffleRuby
  #   @param port [Ractor::Port] The port to monitor.
  #   @return [Boolean]
  #     `true` if the Ractor is running and the port was successfully monitored,
  #     `false` if the Ractor is already terminated and the port received the Ractor's status.
  #   @see #unmonitor
  #
  # @!method unmonitor(port)
  #   Stops monitoring the given port for termination of the Ractor. If the port was not being monitored, this method
  #   has no effect.
  #   @ruby CRuby 4.0+, JRuby, TruffleRuby
  #   @return [self]
  #   @see #monitor
  #
  # @!method name
  #   @return [String, nil] The name of the Ractor, or `nil` if it has no name.
  #
  # @!method receive(timeout: nil)
  #   Receives a message on the Ractor's {#default_port default port}.
  #   @param timeout [Numeric, nil] The timeout in seconds, or `nil` for no timeout.
  #   @return [BasicObject, nil] The received message, or `nil` if the timeout has been reached.
  #
  # @!method send(message, move: false)
  #   Sends a message to the Ractor's {#default_port default port}.
  #   @param message [BasicObject] The message to send.
  #   @param move [Boolean] Whether to move the message to the Ractor if it isn't sharable.
  #   @return [self]
  #
  # @!method name
  #   @return [String, nil] The name of the Ractor, or `nil` if it has no name.
  #
  # @!method receive(timeout: nil)
  #   Receives a message on the Ractor's {#default_port default port}.
  #   @param timeout [Numeric, nil] The timeout in seconds, or `nil` for no timeout.
  #   @return [BasicObject, nil] The received message, or `nil` if the timeout has been reached.
  #
  # @!method send(message, move: false)
  #   Sends a message to the Ractor's {#default_port default port}.
  #   @param message [BasicObject] The message to send.
  #   @param move [Boolean] Whether to move the message to the Ractor if it isn't sharable.
  #   @return [self]
  #
  # @!method value
  #   Blocks the current Thread until the Ractor has terminated, and returns the value returned by the
  #   Ractor's block. Will re-raise any unhandled exception raised in the Ractor's block.
  #   @ruby CRuby 4.0+, JRuby, TruffleRuby
  #   @return [BasicObject] The value returned by the Ractor's block.
  #
  # @!method take
  #   @deprecated
  #     This method only exists on CRuby 3.x (outdated Ractor API). Use {#value} if you don't have to support
  #     CRuby 3.x, or use {Farce::Port}.
  #   Receives a message from the Ractor. This may be the ractor's return value.
  #   @ruby CRuby 3.x
  #   @return [BasicObject] The received message.
  module Ractor
    include Internal::MarshalSupport::Reject
    ::Ractor.include(self) if Internal.native_ractors?

    # @!parse
    #   # @!scope class
    #   alias recv receive
    #   alias recv receive
    #   alias << send

    # Either `Ractor::Error` or a subclass of `RuntimeError` if native Ractors are not available.
    # @!macro RactorError_note
    #   Will pick up an error class defined by a shim/polyfill if one is loaded,
    #   like [ractor-shim](https://github.com/eregon/ractor-shim).
    Error = defined?(::Ractor::Error) ? ::Ractor::Error : Class.new(RuntimeError)

    # Either `Ractor::ClosedError` or a subclass of `StopIteration` if native Ractors are not available.
    # @!macro RactorError_note
    ClosedError = defined?(::Ractor::ClosedError) ? ::Ractor::ClosedError : Class.new(StopIteration)

    # Either `Ractor::IsolationError` or a subclass of {Error} if native Ractors are not available.
    # @!macro RactorError_note
    IsolationError = defined?(::Ractor::IsolationError) ? ::Ractor::IsolationError : Class.new(Error)

    # Either `Ractor::MovedError` or a subclass of {Error} if native Ractors are not available.
    # @!macro RactorError_note
    MovedError = defined?(::Ractor::MovedError) ? ::Ractor::MovedError : Class.new(Error)

    # Either `Ractor::RemoteError` or a subclass of {Error} if native Ractors are not available.
    # @!macro RactorError_note
    RemoteError = defined?(::Ractor::RemoteError) ? ::Ractor::RemoteError : Class.new(Error)

    # Either `Ractor::UnsafeError` or a subclass of {Error} if native Ractors are not available.
    # @!macro RactorError_note
    UnsafeError = defined?(::Ractor::UnsafeError) ? ::Ractor::UnsafeError : Class.new(Error)

    # Either `Ractor::MovedObject` or a subclass of `BasicObject` if native Ractors are not available.
    # Cannot be instantiated directly, but can be used to check if an object has been moved to another Ractor.
    MovedObject = defined?(::Ractor::MovedObject) ? ::Ractor::MovedObject :
      Class.new(BasicObject) { def self.new(...) = raise TypeError, "allocator undefined for #{inspect}" }

    extend Internal::RactorMethods

    def self.const_missing(name) = name == :Port ? Internal::BasePort : super
    private_class_method :const_missing

    # @!visibility private
    def self.included(base)
      return if base.const_defined?(:Port, false)
      base.const_set(:Port, Internal::BasePort)
    end
  end
end
