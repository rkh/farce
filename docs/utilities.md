<!--
# @title Utilities and Custom Classes
-->

# Utilities and Custom Classes

Farce provides helpers for converting object graphs, sharing custom classes, timing work, and coordinating access to values. Use these when adapting an existing library or building your own concurrency tools.

## Top Level Methods

* `Farce.clock` returns the monotonic clock time in seconds as a Float.
* `Farce.config` returns the global configuration object.
* `Farce.configure` allows you to configure Farce.
* `Farce.dedup` de-duplicates the given object based on a deduplication cache shared by all Ractors.
* `Farce.enfarce` turns a vanilla data structure into its Farce equivalent.
* `Farce.freeze_graph` recursively freezes an object graph.
* `Farce.in_parallel`, `Farce.on_main`, and `Farce.schedule`, see [Scheduling Code](scheduling.md#scheduling-code)
* `Farce.rebind` rebinds a proc or lambda while preserving its Ractor-shareability.
* `Farce.transaction` creates and runs a [transaction](concurrency.md#transactions).

Some examples:

```ruby
a = { a: [+"b"] }
b = { a: [+"b"] }

# Farce.clock
Farce.clock         # => 0.017476999908685684
Farce.clock(in: 10) # => 10.017520000003278

# Farce.dedup
a.equal? b                           # => false
Farce.dedup(a).equal? Farce.dedup(b) # => true

# Farce.enfarce
Farce.enfarce(a)         # => #<Farce::Map {a: #<Farce::Vector ["b"]>}>
Farce::Strict.enfarce(a) # => #<Farce::Strict::Map {a: #<Farce::Strict::Vector ["b"]>}>

# Farce.freeze_graph
Farce.freeze_graph(a)

# Farce.rebind
callback = ->(add) { self + add }
rebound  = Farce.rebind(callback, self: 42)
rebound.call(18) # => 60
```

## Additional Classes

Other classes Farce provides include:
* `Config`: Configuration class, see [Third-Party Fiber Schedulers](scheduling.md#third-party-fiber-schedulers) example.
* `ClassMirror`: inheritance-aware registry for classes
* `Clock`: Timing functions based on a monotonic clock rather than on `Time`.
* `Deduper`: Create your own deduplication cache. Direct usage isn't recommended, use [`Farce.dedup`](#top-level-methods) instead.
* `Exchanger`: A synchronization point for two-way data swapping between Threads, Ractors, and/or Fibers. Drop-in replacement for concurrent-ruby's exchanger.
* `Extension`: Defines extensions for existing classes that can either be activated globally or used as refinements.
* `Lazy`: Lazily initialized value.
* `LazyRef`: A [reference](data-structures.md#references) for a lazily initialized value.
* `ThreadExecutor`: A [task executor](scheduling.md#scheduling-code) creating a new thread for each unit of work. Used on TruffleRuby.
* `Walker`: A tool for walking a Ruby object tree.
* `WeakValue`: A value object version of [`WeakRef`](shims.md#weakref). Allows handling references more explicitly, without automatic method delegation.

In addition, Farce includes a range of error classes not listed here. Check the [API documentation](https://rkh.github.io/farce/) or [code base](https://github.com/rkh/farce/blob/main/lib/farce/error.rb) for these.

## Shareability Mixins

Farce includes mixins to help you make your custom classes shareable:

* `Shareable` automatically marks objects as shareable (via `Ractor.make_shareable`) after initialization.
* `Shareable::Delegated` delegates `freeze` and `frozen?` to another object holding your object's state.
* `Shareable::Immutable` instances are always immutable, being frozen after initialization.
* `Shareable::Native` is for objects implemented in a native extension, which allows setting the frozen and shareable state separately.
* `Shareable::Tracked` for objects implementing frozen tracking (via an internal [flag](data-structures.md#flags)).
* `Shareable::Unfreezable` for objects that cannot be frozen (like [queues](data-structures.md#queues)).

And also mixins to prevent them from being shareable:

* `Unshareable`: Instances aren't shareable and cannot be made shareable. By default, they also cannot be copied or moved between Ractors.
* `Unshareable::Copyable`: Instances aren't shareable but may be copied to another Ractor.
* `Unshareable::Movable`: Instances aren't shareable but may be moved to another Ractor.

`Unshareable::Copyable` and `Unshareable::Movable` may be combined.

## Constants

* `Farce::MODES`: List of supported [sharing modes](sharing.md#sharing-modes).
* `Farce::NULL_PORT`: A special `Ractor::Port` that acts as a sink for messages and never closes.
* `Farce::SCOPES`: List of [provided scopes](variants-and-scopes.md#provided-scopes).
* `Farce::VERSION`: The current version.

## Read Next

[README](../README.md#features) · [Sharing Unshareable Data](sharing.md) · [Integrations](integrations.md)
