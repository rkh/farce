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

## Backports

While Farce includes `Farce::Ractor` and `Farce::Port`, it does not backport any methods to the standard `Ractor` class.

Instead, backports are provided by `Farce::Backports`.

### Available Backports

#### From Ruby 4.0

The following methods are added to `Ractor` on Ruby versions prior to 4.0:

- [`default_port`](https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-default_port)
- [`monitor`](https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-monitor)
- [`unmonitor`](https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-unmonitor)
- [`join`](https://docs.ruby-lang.org/en/4.0/Ractor.html#method-i-join)

#### From Ruby 4.1

The following methods are added to `Ractor` on Ruby versions prior to 4.1:

- [`alive?`](https://docs.ruby-lang.org/en/master/Ractor.html#method-i-alive-3F)

No breaking changes are backported. This includes the updated [`monitor`](https://docs.ruby-lang.org/en/master/Ractor.html#method-i-monitor) behavior. The [polyfill](#ractor) will choose its `monitor` implementation based on `RUBY_VERSION` (so that any code checking the Ruby version will see the behavior it should).

### Without Activating Backports

You can call these methods on `Farce::Backports`, directly, passing in the Ractor instance as a first argument.

```ruby
ractor     = Farce::Ractor.new { sleep 1; raise "I'm not happy!" }
supervisor = Farce::Ractor.new { puts "status: #{receive}" }
port       = Farce::Backports.default_port(supervisor)

# This will print "status: aborted" in approximately one second
Farce::Backports.monitor(ractor, port)

# Wait for the supervisor to receive the status
Farce::Backports.join(supervisor)
```

### Using Backports via Refinements

You can activate the backports for a lexical scope (within a file, or even just within a module within a file, or starting with Ruby 4.1 for an individual block) using them as a [refinement](https://docs.ruby-lang.org/en/master/syntax/refinements_rdoc.html):

```ruby
# only activates the backports for the current file
using Farce::Backports

# Refinements can't install constants, so we still need to use Farce::Ractor for JRuby/TruffleRuby
# If you know you're on CRuby, you can replace Farce::Ractor with Ractor
ractor     = Farce::Ractor.new { sleep 1; raise "I'm not happy!" }
supervisor = Farce::Ractor.new { puts "status: #{receive}" }

# These methods now work regardless of whether you used Ractor or Farce::Ractor
port = supervisor.default_port
ractor.monitor(port)
supervisor.join
```

### Activating Backports Globally

You can activate backports globally. As these don't override built-in methods, doing so should only cause issues for code expecting these methods not to be defined based on the `RUBY_VERSION` string.

Anywhere before executing your code, like an initializer:

```ruby
Farce::Backports.install
```

Now you can do this in any file:

```ruby
# After installing backports globally, Ractor will always be defined
ractor     = Ractor.new { sleep 1; raise "I'm not happy!" }
supervisor = Ractor.new { puts "status: #{receive}" }
ractor.monitor(supervisor.default_port)
supervisor.join
```

## WeakRef

`Farce::WeakRef` is a drop-in replacement for Ruby's [`WeakRef`](https://docs.ruby-lang.org/en/4.0/WeakRef.html), which at the time of writing cannot be used outside of the main Ractor at all.

Farce implements a version based on weak [atoms](data-structures.md#atoms). Not only can it be used on non-main Ractors, `Farce::WeakRef` instances themselves are Ractor-shareable if the value they reference is also Ractor-shareable (or has been garbage collected). Moreover, calling `Ractor.make_shareable(weak_ref)` will propagate through to the referenced value.

## Resolv

`Farce::Resolv` is a version of Ruby's [`Resolv`](https://docs.ruby-lang.org/en/4.0/Resolv.html), using [counters](data-structures.md#counters) instead of a global instance variable, and can therefore be used outside the main Ractor.

## Read Next

[README](../README.md#features) · [Sharing Unshareable Data](sharing.md) · [Scheduling Code](scheduling.md)
