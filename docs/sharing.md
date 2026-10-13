<!--
# @title Sharing Unshareable Data
-->

# Sharing Unshareable Data

Ruby's `Ractor::Port#send` and related methods share Ruby objects between Ractors with this logic:

1. If the object is Ractor shareable, pass it by reference.
2. If the object isn't Ractor shareable and the `move` option hasn't been set to `true`, pass it by value (copy it).
3. Otherwise move it from the sending Ractor to the receiving Ractor, invalidating any previous references.

This is a great start but has some complications:
* Copying can lead to a lot of data duplication, as large object trees may be copied between Ractors over and over again.
* Moving may invalidate nested references unexpectedly, breaking code in the sending Ractor.
* If you want to prevent sending unshareable objects to other Ractors, you have to manually check them every time.

Farce has mechanisms and tools to improve the situation.

## Sharing Modes

> [!TIP]
> Learn more in the dedicated  [modes documentation](modes.md).

The [default variants](variants-and-scopes.md#variants-and-scopes) of most [data structures](data-structures.md#data-structures), as well as [`Farce::Port`](shims.md#port), implement a range of sharing modes, typically as a keyword argument for initialization as well as for methods that modify their content.

These modes are:

| Mode | What happens to non-shareable data | A typical use |
| --- | --- | --- |
| `:smart` (default) | Applies smart rules or a dedicated proxy, raising for unsupported values. | Share supported values with less copying. |
| `:smart_raise` | Applies smart rules or a dedicated proxy, with a raising fallback. | Reject unsupported transfers. |
| `:smart_copy` | Applies smart rules or a dedicated proxy, then tries copying and Marshal. Default for `Farce::Port`. | Send values with a copying fallback. |
| `:smart_move` | Applies smart rules or a dedicated proxy, then tries moving. | Hand off unsupported values. |
| `:copy` | Transfers a copy and leaves the original usable. | Send a snapshot of a request. |
| `:marshal` | Serializes a snapshot and reconstructs it once per receiving Ractor. | Transfer an Unshared container.|
| `:move` | Transfers ownership and makes the original inaccessible. | Hand a completed batch to a consumer. |
| `:local` | Keeps the same object in its originating Ractor. | Pass work between local threads or fibers. |
| `:make_shareable` | Calls `Ractor.make_shareable` on the original. | Publish finished configuration. |
| `:mutable` | Copies non-shareable objects into a [`Farce::Mutable`](#mutables). | Synchronize mutations across Ractors. |
| `:shareable_copy` | Makes a shareable copy and leaves the original alone. | Publish a snapshot of an editable document. |
| `:dedup` | Deduplicates the value, then makes it shareable. May update and freeze the original. | Reuse repeated message contents. |
| `:proxy` | Creates a [`Farce::Proxy`](#proxies) that executes calls in the original Ractor. | Share access to a mutable object. |
| `:raise` | Raises `Ractor::IsolationError`. | Enforce a shareable-data boundary. |

Here's an example:

```ruby
map = Farce::Map.new(mode: :mutable)
map[:content] = "Hi there!"

Ractor.new(map) { it[:content] << " How are you doing?" }.join

# Hi there! How are you doing?
puts map[:content]
```

## Envelopes

Farce allows you to explicitly wrap an object in an envelope. This is useful if you want to pass a value around between multiple Ractors (or multiple times between the same Ractors) without copying, wrapping, converting, or moving it every single time.

Instead, you can wrap it in an envelope, and then later explicitly retrieve the value again.

```ruby
# We don't want to copy this over and over again.
big_array = 10_000.times.map { rand }
envelope  = Farce::Envelope.new(big_array) # copied in once, copied out on demand

Ractor.new(envelope) do |envelope|
  # we have a reference to envelope, but not a copy of its data
  # this allows us to pass it on easily
  queue = Farce::Queue.new(mode: :raise)
  queue.push(envelope) # this is okay, the envelope is shareable

  # We can pass the envelope by other means, like a queue!
  Ractor.new(queue) do |queue|
    message = queue.pop
    # okay, let's get the copy, bypassing the outer ractor
    copy_of_array = message.value
    puts "Size of the array: #{copy_of_array.size}"
  end
end
```

Envelopes support `copy`, `move`, `local`, as well as a dummy envelope for wrapping shareable objects.

## Mutables

Mutables are special wrappers for Ruby objects that are Ractor-shareable when frozen but can be modified when not.

```ruby
mutable = Farce::Mutable.new("content")
Ractor.new(mutable) { it << " & additional content" }.join
mutable # => #<Farce::Mutable[String] "content & additional content">
```

They expose a mutable API by keeping a frozen snapshot of the wrapped object, atomically unfreezing, mutating, and freezing it whenever a method otherwise throws a `FrozenError`. This means non-mutating methods have almost no additional cost, and in contrast to [proxies](#proxies), method calls do not have to be dispatched across Ractors, even when modifying the object. However, mutating methods will copy the wrapped object's content. This may be fine, but could be expensive when used repeatedly on large objects.

## Proxies

A proxy mimics the API of another object, executing method calls within the Ractor that created it. This is an easy way to have drop-in replacements for objects that cannot be shared across Ractors.

```ruby
# Mutable arrays aren't Ractor-shareable
array   = []
proxied = []
proxy   = Farce::Proxy.new(proxied)

Farce::Ractor.new(array, proxy) do |*list|
  list.each { it << 42 }
end.join

# The array got copied instead of being modified in place
array # => []

# The proxy didn't get copied
proxied # => [42]
```

Use this for very large objects, where copying the object would be more expensive than the Ractor-coordination overhead, or objects that can not be moved or copied between Ractors.

The downside is a dispatch to another Ractor on every method call.
If copying on writes is an option, consider [`Farce::Mutable`](#mutables) instead.
If the object may be moved across Ractors, maybe a [`Farce::Lease`](#leases) is a better option.

There is an advanced [customization API](https://rkh.github.io/farce/main/Farce/Proxy.html), which allows fine-tuning and reducing overhead.

## Mode Managers

You can use a mode manager if you want to support sharing modes for a custom object.

The mode manager might wrap objects in an envelope. It also exposes a method to unwrap objects again, which will only do so for envelopes created by the specific mode manager. That's why we were able to pass an envelope through the queue in the [example above](#envelopes) without it getting opened automatically.

```ruby
manager = Farce::ModeManager.new(mode: :move)
payload = ["inside a mutable array"]
Ractor.shareable?(payload) # => false

shareable = manager.wrap(payload) # => #<Farce::Envelope::Move>
Ractor.shareable?(shareable) # => true

payload = shareable.value
Ractor.shareable?(payload) # => false
```

## Leases

You can think of a `Farce::Lease` as a reusable `move` envelope. Or [Haskell's MVar](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Concurrent-MVar.html) if that's more your jam.

You can store any object in it, including non-shareable ones (if they are movable). A Ractor can check objects out (at which point they get moved into that Ractor), work with them, and move them back into the lease container. The checkout call will block while another Ractor holds the lease, serializing any operations.

This is very useful for objects that can be moved but can't be copied, especially IO-based objects like database connections.

```ruby
file_lease = Farce::Lease.new { File.open("example.txt", "w") }

Ractor.new(file_lease) do |file_lease|
  file_lease.checkout do |file|
    file.puts "Written from another Ractor!"
  end
end.join

# make sure we close the file
file_lease.checkout(&:close)

# dereference the lease so it can be garbage collected
file_lease = nil
```

However, this might not be enough for handling database connections, where you'd usually have a pool of connections. You can use `Farce::LeasePool` which will manage multiple objects, only blocking on `checkout` if all objects have been leased.

Moreover, it can generate these objects for you on demand (until a certain number has been reached).

```ruby
# db connections are created on demand if there are fewer than five
pool = Farce::LeasePool.new(max_size: 5) { DB.connect }
pool.size     # => 0
pool.max_size # => 5

pool.checkout do |db|
  # ... do something with db ...
end
```

Or, if you want to associate leasable values with keys, you can use a `LeaseMap`:

```ruby
leases = Farce::LeaseMap.new { { primary: [], replica: [] } }
leases.checkout(:primary) { |items| items << :updated }
leases.checkout(:primary, &:dup) # => [:updated]
```

At first glance, this looks just like a [map](data-structures.md#maps) of `Lease` instances. And it pretty much is, except it has some nice tooling on top of it, where it can automatically check values out and back in:

```ruby
leases = Farce::LeaseMap.new { { primary: [], replica: [] } }

leases.auto_lease do
  leases[:primary] << :updated
  leases[:replica] << :replicated
  leases[:primary] << :verified # Reuses the same checkout
end

# Both resources are checked back in when the block exits, even on an exception.
leases.available?(:primary) # => true
leases.checkout(:primary, &:dup) # => [:updated, :verified]
```

## Read Next

[README](../README.md#features) · [Transfer modes](modes.md) · [Data Structures](data-structures.md)
