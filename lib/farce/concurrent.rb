# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Module to replace some functionality of `concurrent-ruby` with.
  #
  # Nested in a separate module so it can easily be moved into a dedicated gem
  # (this would only happen on a major release).
  #
  # Not all of them are full drop-in replacements, especially when it comes to matching superclasses.
  #
  # If it matches the subset of functionality you need you could replace this:
  #
  # ```ruby
  # require "concurrent"
  # ```
  #
  # With this:
  #
  # ```ruby
  # require "farce"
  # Concurrent = Farce::Concurrent
  # ```
  #
  # If developing a gem or just part of a larger app, you can and should do this under a namespace rather than globally.
  #
  # @see https://ruby-concurrency.github.io/concurrent-ruby/
  module Concurrent
    include Internal::Autoloads

    Array         = Vector
    Atom          = Farce::Atom
    AtomicBoolean = Flag
    AtomicFixnum  = Counter
    Exchanger     = Farce::Exchanger
    Hash          = Farce::Map
    Lock          = Farce::Lock
    Map           = Farce::Map
    ReadWriteLock = Farce::ReadWriteLock

    autoload :LockLocalVar, "farce/concurrent/fiber_local_var"
    private_constant :LocalVar
  end
end
