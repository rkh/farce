<!--
# @title Data Structures
-->

# Data Structures

Farce provides a range of data structures that are ractor-safe, mutable, and expose high-level concurrency APIs in addition to standard Ruby APIs for the built-in classes it offers replacements for.

## Contents

- [Data Structures](#data-structures)
  - [Contents](#contents)
  - [Maps](#maps)
  - [Vectors](#vectors)
  - [Sets](#sets)
  - [Atoms](#atoms)
  - [Counters](#counters)
  - [Flags](#flags)
  - [References](#references)
  - [Molecules](#molecules)
  - [Queues](#queues)
    - [Priority Queues](#priority-queues)
    - [Timer Queues](#timer-queues)
    - [Queue capacity](#queue-capacity)
  - [Publishers](#publishers)
  - [Read Next](#read-next)

## Maps

Maps are Hash-like key-value data structures. They do not preserve insertion order.

They implement almost all methods Ruby's Hash offers:

```ruby
map       = Farce::Map.new
map[:foo] = :bar

map.merge! answer: 42
map.transform_values! { -it.to_s }
map.to_h # => {answer: "42", foo: "bar"}
```

In addition, they come with a range of [atomic operations](concurrency.md#atomic-operations), and have built-in key normalization support:

```ruby
# normalize_keys can be a symbol, proc, hash, or another map
map = Farce::Map.new({ a: 10 }, normalize_keys: :to_s)

# Atomic upsert operation
2.times { map.upsert(:b, 42) { it * map[:a] } }

# Keys have been converted to strings
map.keys.sort # => ["a", "b"]
```

Besides the standard map implementation, Farce includes a range of specialized maps:

* `LRUMap` will evict the least recently used entry to not grow beyond the maximum size.
* `LFUMap` will evict the least frequently used entry to not grow beyond the maximum size.
* `LeaseMap` manages [leases](sharing.md#leases) associated with known keys.
* `TreeMap` uses a [red-black tree](https://en.wikipedia.org/wiki/Red%E2%80%93black_tree) instead of a [hash table](https://en.wikipedia.org/wiki/Hash_table) to store its entries, keeping them sorted by the key's value.
* `WeakMap` only holds weak references to its keys and values, automatically removing entries when the corresponding key or value gets garbage collected.
* `WeakKeyMap` only holds weak references to its keys, automatically removing entries when the corresponding key gets garbage collected.
* `WeakValueMap` only holds weak references to its values, automatically removing entries when the corresponding value gets garbage collected.

For example, bounded maps are useful for implementing caches:

```ruby
cache = Farce::LRUMap.new(max_size: 2)

cache[:first]  = 1
cache[:second] = 2
cache[:first] # makes sure :first was accessed more recently than :second
cache[:third]  = 3

cache.key?(:second) # => false
```

## Vectors

`Farce::Vector` is to `Array` what `Farce::Map` is to `Hash`. It implements the same interface, with additional atomic operations.

```ruby
list = Farce::Vector.new
10.times { list << it }
list.to_a # => [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
list.sum  # => 45
```

There is one important difference to arrays: Bulk mutations, such as `Vector#map!` are atomic. Either the block succeeds for all entries, or if it raises an exception then none of the changes are applied. Such mutations may also not write to the same vector from within the block.

```ruby
list = Farce::Vector[1, 2, 3, 4]

begin
  list.map! do |value|
    raise "error" if value == 2
    value * 2
  end
rescue => e
end

# This would return 2 if list was an array
list.first # => 1
```

## Sets

`Farce::Set` is to `Set` what `Farce::Map` is to `Hash`. It implements the same interface, with additional atomic operations.

```ruby
jobs = Farce::Set[:compile, :test]
jobs.add? :publish    # => jobs
jobs.add? :test       # => nil
jobs.include? :publish # => true
```

Besides the standard set implementation, Farce includes two specialized sets:

* `SortedSet` keeps its entries in order based on value comparison.
* `WeakSet` only holds weak references to its entries.

## Atoms

Atoms are value containers. These store a single reference to any Ruby object, and expose atomic operations for mutating these values:

```ruby
atom = Farce::Atom.new("initial value")
atom.value # => "initial value"

# atoms are ractor-shareable
Ractor.new(atom) do |atom|
  atom.update { |current| current + " updated" } # => "initial value updated"
end

# waits for the other ractor to perform its update
atom.wait_until_changed "initial value"
```

`WeakAtom` only keeps a weak reference for its current value, reverting to `nil` when the current value gets garbage collected.

## Counters

Ractor-shareable, atomic counter. This is a stateful, numeric object.

It is similar to creating an [atom](#atoms) for an integer, but significantly faster, as it will use a truly lock-free implementation on most CPU/Ruby combinations.

```ruby
counter = Farce::Counter.new
counter.value # => 0

# Increase the counter by 1
counter.increment
counter.value # => 1

# Increase the counter by 5 on another Ractor
Ractor.new(counter) { it.add(5) }.join

counter.value # => 6
```

## Flags

Ractor-shareable, atomic boolean.

Just like Counter for Integer, this is similar to creating an [atom](#atoms) for a boolean, but significantly faster, as it will use a truly lock-free implementation on most CPU/Ruby combinations.

```ruby
flag = Farce::Flag.new(true)
flag.value # => true
```

## References

Atoms, as well as other value objects, like counters and flags, can be wrapped in a reference object, which delegates all methods to the given atom for convenience:

```ruby
atom = Farce::Atom.new(42)
ref  = Farce::Reference.new(atom)

ref.to_s  # => "42"
ref > 10  # => true

atom.value = :foo
ref.to_s  # => "foo"
```

## Molecules

Molecules are structures made up of multiple atoms. Clever naming, right?

They are similar to Ruby's built-in `Struct` and `Data` classes, but their members are stored in atoms:

```ruby
Request = Farce::Molecule.define(:verb, :path)
request = Request.new("GET", "/index.html")
request.verb  # => "GET"
request.verb = "POST"

# This doesn't succeed, as the verb isn't "HEAD"
request.verb_atom.compare_and_set("HEAD", "GET")
request.verb  # => "POST"
```

You can also pass a block to add additional methods:

```ruby
Request = Farce::Molecule.define(:verb, :path) do
  def to_s = "#{verb} #{path}"
end

Request.new(verb: "GET", path: "/").to_s  # => "GET /"
```

You can also inherit from the generated class:

```ruby
class Request < Farce::Molecule.define(:verb, :path)
  def to_s = "#{verb} #{path}"
end
```

## Queues

`Farce::Queue` is an alternative to Ruby's `Queue` and `SizedQueue`. It provides a superset of their API, offering both blocking and a non-blocking API, while implementing Ractor-sharing via [sharing modes](sharing.md#sharing-modes).

```ruby
queue = Farce::Queue.new
queue.push(:ok)
queue.pop     # => :ok
queue.try_pop # => nil
```

Queues provide additional features over Ruby's queue:
* Like the rest of Farce, they work with Ractors (implementing [sharing modes](sharing.md#sharing-modes) for their [default variant](variants-and-scopes.md#variants-and-scopes)).
* In addition to closing, they allow sealing, which prevents pushes but still allows pulling from the queue until it has been drained.
* They have an API to wait for them to be ready for a push or pull based on capacity without actually adding or removing values.
* They can optionally monitor how long the oldest item has been sitting in the queue (which is great for building auto-scaling on top of the queue).

The [strict variant](variants-and-scopes.md#available-variants) has comparable performance to `SizedQueue`, while the default variant pays a fixed overhead for [handling unshareable data](sharing.md#sharing-unshareable-data). Both variants outperform other third-party, Ractor-shareable queues (none of which are Fiber scheduler compatible, which Farce's queues are).

### Priority Queues

In addition to normal queues, which are FIFO, Farce also offers a `PriorityQueue`, where values are removed from the queue in order of priority instead of insertion order:

```ruby
# use order: :descending to reverse priorities
queue = Farce::PriorityQueue.new

queue.push :a, priority: 2
queue.push :b, priority: 1

queue.pop # => :b
```

### Timer Queues

Timer queues are similar to priority queues, sorted by float values, but these values are timestamps (based on [Farce::Clock](utilities.md#additional-classes), not on Ruby's Time, which isn't monotonic). Any `pop` will block until the next timestamp has been reached.

```ruby
queue = Farce::TimerQueue.new
queue.push(:ok, in: 1.5)

# blocks for ~1.5 seconds
queue.pop # => :ok
```

Timer queues are useful for implementing schedulers (which is what Farce uses them for under the hood). Both `push` and `try_push` return a cancellation handle when they succeed. Use `entry.delete` or `queue.delete(entry)` to cancel a scheduled value. The handle exposes its `queue` and scheduled `clock` time.

```ruby
queue = Farce::TimerQueue.new
entry = queue.push(:work, in: 60)

entry.delete # => true
```

You can also delete a value if you know its timestamp:

```ruby
queue     = Farce::TimerQueue.new
timestamp = Farce.clock(in: 0.2)

queue.push(:first,  at: timestamp - 0.1)
queue.push(:second, at: timestamp)
queue.push(:third,  at: timestamp + 0.1)

fourth = queue.push(:fourth, at: timestamp + 0.2)
queue.delete(fourth)

queue.delete(:second, at: timestamp)

result = []
result << queue.pop until queue.empty?
result # => [:first, :third]
```

### Queue capacity

Queues support setting a maximum capacity. If the capacity has been reached it will block any pushes to create back pressure.

```ruby
queue = Farce::Queue.new(capacity: 2)

queue.try_push(:a) # => true
queue.try_push(:b) # => true
queue.try_push(:c) # => false
```

Normal queues have a default capacity of 1024. You can explicitly set the capacity to `nil` to create an unbounded queue.
Priority queues and timer queues do not have a default capacity, so earlier entries are not getting blocked unexpectedly.

## Publishers

Both ports and queues deliver messages exactly ones. Multiple receivers can read from the same port (if they are running inside the same ractor) or queue, but each message will only be delivered once.

A publisher allows one-to-many communication, where a single publisher can broadcast messages to multiple subscribers. Published messages are sent to enabled subscribers.

Subscribers can be:

* Ractors, ports, queues, or other publishers, using their respective message sending mechanisms.
* A [vector](#vectors) or [set](#sets), in which case each message will be added to the collection.
* A [counter](#counters), incrementing it for each message received. This avoids potential copying of the message itself.
* A [flag](#flags), setting it to true whenever a message is received. This avoids potential copying of the message itself.
* A `Farce::Concurrent::Event`, setting it for each message received.
* A `Farce::Concurrent::CountDownLatch`, counting down for each message received.
* A callback, executed for each message received.

For unshared and local publisher [variants](variants-and-scopes.md) subscribers may also include:

* Any unshared variant of the subscriber list above.
* Ruby's `Thread::Queue` or `Thread::SizedQueue`
* `Concurrent::AtomicReference`, `Concurrent::AtomicFixnum`, `Concurrent::AtomicBoolean`, `Concurrent::Event`, and `Concurrent::CountDownLatch` if the [concurrent-ruby integration](integrations.md#concurrent-ruby) is active.

```ruby
publisher = Farce::Publisher.new
counter   = Farce::Counter.new

publisher.subscribe do |message|
  puts "Received: #{message}"
end

publisher.publish(:hello)
publisher.publish(:world)

counter.to_i # => 2
```

## Read Next

[README](../README.md#features) · [Sharing Unshareable Data](sharing.md) · [Concurrency](concurrency.md) · [Variants and Scopes](variants-and-scopes.md)
