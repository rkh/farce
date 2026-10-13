<!--
# @title Shims, Polyfills, and Extensions
-->

# Shims, Polyfills, and Extensions

Farce adapts Ruby APIs for use across Ractors and with Fiber schedulers. Its Ractor and Port implementations also provide fallbacks on Ruby engines without native Ractors.

## Ractor

Farce includes `Farce::Ractor`, which will either delegate to `Ractor` or supply a polyfill for it.

On platforms that don't support Ractors, a Thread-based implementation is provided that tracks Ractor-membership via Thread
groups.

```ruby
ractor = Farce::Ractor.new do
  value = receive
  puts "Received #{value.inspect}"
end

ractor.send 42
```

## Port

Farce includes `Farce::Port`, which is either an extended subclass of `Ractor::Port` if it is available, or a polyfill if it isn't.

In addition to `Ractor::Port` it supports the following features:
* [Sharing modes](sharing.md#sharing-modes) both for `.new` and `#send`.
* Opt-in auto-local sharing: If the port belongs to the current Ractor, any object can be sent to it without copying or moving it.
* `#receive` supports a `timeout` option on all Ruby implementations and versions, not just CRuby 4.1+
* You can use `#owned?` to check if the current Ractor owns a port.
* `#receive` does not block a Fiber scheduler when called from a non-blocking Fiber.

```ruby
# reject unshareable values except if they are being sent from the ractor owning the port
port   = Farce::Port.new(mode: :raise, auto_local: true)
object = Object.new

port.send(object)
port.receive.equal?(object) # => true
```

## WeakRef

`Farce::WeakRef` is a drop-in replacement for Ruby's [`WeakRef`](https://docs.ruby-lang.org/en/4.0/WeakRef.html), which at the time of writing cannot be used outside of the main Ractor at all.

Farce implements a version based on weak [atoms](data-structures.md#atoms). Not only can it be used on non-main Ractors, `Farce::WeakRef` instances themselves are Ractor-shareable if the value they reference is also Ractor-shareable (or has been garbage collected). Moreover, calling `Ractor.make_shareable(weak_ref)` will propagate through to the referenced value.

## Resolv

`Farce::Resolv` is a version of Ruby's [`Resolv`](https://docs.ruby-lang.org/en/4.0/Resolv.html), using [counters](data-structures.md#counters) instead of a global instance variable, and can therefore be used outside the main Ractor.

## Read Next

[README](../README.md#features) · [Sharing Unshareable Data](sharing.md) · [Scheduling Code](scheduling.md)
