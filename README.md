# Farce: Fiber and Ractor Compatibility Enabler

Farce provides tools and data structures to write code that works well with both **Fiber schedulers** and **Ractors**, as well as the classic **Threads**. Its main purpose is to be used by other gems to provide better compatibility with these concurrency primitives, but it can also be used directly in applications.

**Here's a taste:**

```ruby
map    = Farce::Map.new
output = Farce::Mutable.new "Hello from Farce! The map has 0 entries, with a total sum of 0."

# Mutate output in another Ractor - this would not work with a String.
# Using Farce::Ractor here instead of Ractor so it also works on JRuby and TruffleRuby.
ractor = Farce::Ractor.new(output) do |output|
  sleep rand # I laugh in the face of race conditions. Ha, ha, ha, ha!
  output.gsub!("Farce", "✨ Farce ✨")
end

# No idea if the above ractor is done modifying output, but we don't need to worry!
# We'll just pick a random key one hundred times and increase its counter by one.
# Oh, and update the output string.
100.times.map do

  # And of course we need to do it all in parallel for maximum performance!
  # Let's ignore the fact that this would be much faster if we didn't.
  # Starting 100 ractors is the main performance issue here.
  # But that wouldn't be an interesting example, right?
  Farce::Ractor.new(output, map) do |output, map|
    key = %i[foo bar baz].sample

    # Wrap the modifications in a transaction, so map and output never disagree
    Farce.transaction(output, map) do |_, output, map|

      # Increase the value we have for the given key by one!
      map[key] ||= 0
      map[key]  += 1

      # Could also replace the lines above with:
      #
      #   map.upsert(key, 1) { it + 1 }
      #
      # … which would be atomic.
      # But we're in a transaction, so everything is atomic! ☢️

      output.sub!(/\d+ entries/, "#{map.size} entries")
      output.sub!(/sum of \d+/, "sum of #{map.values.sum}")
    end
  end

end.each(&:join)

# Let's be sure that first ractor has completed its modification
ractor.join

# Hello from ✨ Farce ✨! The map has 3 entries with a total sum of 100.
puts output
```

🤨 **You don't see why you'd want this?**<br>
→ Start with the [Introduction](#introduction).

📖 **Now you want to know what else Farce can do?**<br>
→ Check out the [Features](#features)!

🔎 **Returning user and you need the details?**<br> 
→ See the [API reference](https://rkh.github.io/farce/).

🛠️ **Want to contribute?**<br>
→ Read the [contribution guide](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), and [security policy](SECURITY.md).


## Table of Contents

- [Farce: Fiber and Ractor Compatibility Enabler](#farce-fiber-and-ractor-compatibility-enabler)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
    - [The Problem](#the-problem)
    - [The Solution](#the-solution)
  - [Features](#features)
    - [Data Structures](#data-structures)
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
    - [Shims, Polyfills, and Extensions](#shims-polyfills-and-extensions)
      - [Ractor](#ractor)
      - [Port](#port)
      - [WeakRef](#weakref)
      - [Resolv](#resolv)
    - [Sharing Unshareable Data](#sharing-unshareable-data)
      - [Sharing Modes](#sharing-modes)
      - [Envelopes](#envelopes)
      - [Mutables](#mutables)
      - [Proxies](#proxies)
      - [Mode Managers](#mode-managers)
      - [Leases](#leases)
    - [Variants and Scopes](#variants-and-scopes)
      - [Available Variants](#available-variants)
      - [Provided scopes](#provided-scopes)
    - [Concurrency](#concurrency)
      - [Locks](#locks)
      - [Atomic Operations](#atomic-operations)
      - [Observability and Signaling](#observability-and-signaling)
      - [Transactions](#transactions)
        - [Maps and Sets](#maps-and-sets)
        - [TVars](#tvars)
    - [Scheduling Code](#scheduling-code)
      - [`Farce.on_main`](#farceon_main)
      - [`Farce.in_parallel`](#farcein_parallel)
      - [`Farce.schedule`](#farceschedule)
      - [Schedulers](#schedulers)
      - [Ractor Pools](#ractor-pools)
      - [Third-Party Fiber Schedulers](#third-party-fiber-schedulers)
    - [Integrations](#integrations)
      - [Active Support](#active-support)
      - [Dry Types](#dry-types)
      - [JSON, YAML, etc](#json-yaml-etc)
      - [Concurrent Ruby](#concurrent-ruby)
      - [Ractor Sharing](#ractor-sharing)
      - [Additional Integrations](#additional-integrations)
      - [Disable Automatic loading](#disable-automatic-loading)
    - [Miscellaneous](#miscellaneous)
      - [Top Level Methods](#top-level-methods)
      - [Additional Classes](#additional-classes)
      - [Shareability Mixins](#shareability-mixins)
      - [Constants](#constants)
  - [Compatibility and Dependencies](#compatibility-and-dependencies)
    - [Ruby](#ruby)
    - [Optional Dependencies](#optional-dependencies)
    - [Similar Projects](#similar-projects)
  - [Installation](#installation)
    - [Globally](#globally)
    - [As a project dependency](#as-a-project-dependency)
    - [As a library dependency](#as-a-library-dependency)
    - [Local setup](#local-setup)
    - [Loading Farce](#loading-farce)
  - [Known Issues and Limitations](#known-issues-and-limitations)
    - [Possible discrepancy regarding frozen state in Ruby and C](#possible-discrepancy-regarding-frozen-state-in-ruby-and-c)
  - [Housekeeping](#housekeeping)


## Introduction

Ruby 3.0 introduced two powerful concurrency primitives: **Fiber schedulers** and **Ractors**, besides the already existing **Threads**:

* **Threads** are the classic concurrency primitive in Ruby, and mostly map to native operating system threads. This way any system calls, IO, or other blocking operations will block a thread, allowing another one to run. However, on the official Ruby implementation (often referred to as CRuby or MRI), Threads cannot run in parallel due to the Global VM Lock (GVL). This means that even if you have multiple threads, only one of them can execute Ruby code at a time.
* **Ractors** provide parallelism, even on CRuby. They make it very hard to introduce concurrency issues between them, but put severe limitations on state sharing and cross-ractor communication. Ractors are only supported by CRuby, but that is generally not an issue, as other implementations, such as JRuby and TruffleRuby, support true parallelism with Threads. As of Ruby 4.0, Ractors are still considered experimental.
* **Fiber schedulers** allow you to run multiple Fibers concurrently on a single Thread, without having to explicitly pass control between them. This is a very efficient way to run concurrent code, especially for IO-bound workloads. As of Ruby 4.0, Fiber schedulers with IO support are still considered experimental.

All three of these need some form of **concurrency coordination** for shared state. These are usually the most complicated for Threads, as state is shared between them freely, and an interrupt can happen at any time. Fibers on the other hand have explicit control transfer (only on blocking operations or when giving up control), so their behavior is much more predictable. Ractors disallow sharing mutable state between them (or have built-in locking for the few cases where they allow it).

### The Problem

> [!NOTE]
> Please keep in mind that many of these libraries may gain better Ractor support in the future, and that the table might already be outdated. Feel free to open an issue if you find any inaccuracies. This is also in no way meant as a criticism of any of the libraries mentioned. They all have their own scopes, goals and priorities, and largely rely on volunteer contributions.

Both the Ruby core library, and other libraries, like the very popular [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) gem, provide plenty of primitives to solve this. However, most of them are not compatible with Ractors. And those that are, are then in turn usually not compatible with Fiber schedulers. Due to this, most of the popular frameworks and libraries out there do not support Ractors at all:

<table>
  <thead>
    <tr>
      <th>Library</th>
      <th>Example classes</th>
      <th>Multithreading</th>
      <th>Non-blocking Fibers</th>
      <th>Cross-Ractor Usage</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td rowspan="5"><a href="https://www.ruby-lang.org/">Ruby</a></td>
      <td>Array, Hash, String, Set, …</td>
      <td>⚠️ not thread-safe</td>
      <td>✅ supported</td>
      <td>⚠️ immutable/copy/move only</td>
    </tr>
    <tr>
      <td>Thread, Fiber</td>
      <td>✅ supported</td>
      <td>✅ supported</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td>Mutex, ConditionVariable, Queue</td>
      <td>✅ supported</td>
      <td>⚠️ CRuby only</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td>Ractor, Ractor::Port</td>
      <td>✅ supported</td>
      <td>❌ <b>not supported</b></td>
      <td>✅ supported</td>
    </tr>
    <tr>
      <td>WeakRef, Ruby::Box</td>
      <td>⚠️ Main Ractor only</td>
      <td>⚠️ Main Ractor only</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td><a href="https://github.com/ruby-concurrency/concurrent-ruby">concurrent-ruby</a></td>
      <td>Future, Exchanger, Tuple, …</td>
      <td>⚠️ Main Ractor only</td>
      <td>⚠️ Main Ractor only</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td rowspan="2"><a href="https://github.com/socketry/async">async</a></td>
      <td>Promise, Condition, Queue, …</td>
      <td>✅ supported</td>
      <td>✅ supported</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td>Scheduler</td>
      <td>⚠️ Main Ractor only</td>
      <td>⚠️ Main Ractor only</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td rowspan="3"><a href="https://github.com/mperham/ratomic">ratomic</a></td>
      <td>Pool</td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>❌ <b>not supported</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
    </tr>
    <tr>
      <td>LocalPool</td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
    </tr>
    <tr>
      <td>Queue, Map</td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>❌ <b>not supported</b></td>
      <td>💣 <b>breaks isolation¹²</b></td>
    </tr>
    <tr>
      <td><a href="https://github.com/MadBomber/ractor_queue">ractor_queue</a></td>
      <td>RactorQueue</td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>💣 <b>breaks isolation¹²</b></td>
    </tr>
    <tr>
      <td>
        <a href="https://github.com/hamstergem/hamster">hamster</a> /
        <a href="https://github.com/immutable-ruby/immutable-ruby">immutable</a>
      </td>
      <td>Hash, Vector, Set, List, …</td>
      <td>⚠️ Main Ractor only</td>
      <td>⚠️ Main Ractor only</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td><a href="https://github.com/ko1/ractor-sharing">ractor-sharing</a></td>
      <td>TVar, LockVar, LockHash, …</td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>❌ <b>not supported</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
    </tr>
    <tr>
      <td rowspan="2"><a href="https://github.com/jhawthorn/ractor_safe">ractor_safe</a></td>
      <td>HashMap, AtomicInteger</td>
      <td>⚠️ CRuby only</td>
      <td>⚠️ CRuby only</td>
      <td>✅ supported</td>
    </tr>
    <tr>
      <td>Queue</td>
      <td>⚠️ CRuby only</td>
      <td>❌ <b>not supported</b></td>
      <td>✅ supported</td>
    </tr>
  </tbody>
</table>

Notes:
1. Incorrectly flags mutable objects as frozen.
2. Breaking Ractor isolation introduces concurrency issues not just in application code, but in Ruby itself, possibly leading to segmentation faults or undefined behavior. Note that `ractor_queue` has the ability to enforce shareability, but this feature is opt-in.

### The Solution

**Farce is an attempt to solve this.** Code relying on Farce will work well with any concurrency primitive. Use an **event loop with the [async](https://github.com/socketry/async)** gem? Farce will fit right in. Running a **pool of Ractors** with [Kino](https://github.com/yaroslav/kino)? Farce got you covered! You manually manage a single **background thread**? Farce solves that, too!

And it does so in a non-invasive way. You should be able to use Farce alongside any other gem!

```ruby
# Using a counter as an example, there are many more classes provided by Farce
counter = Farce::Counter.new

# Works in code without concurrency
counter.add(5)
counter.to_i # => 5

# Works with threads
wait_for = 5.times.map do
  Thread.new { counter.increment }
end

# Works with ractors
wait_for += 5.times.map do
  Ractor.new(counter) { it.increment }
end

# Works with the async gem
Async do
  5.times do
    Async { counter.increment }
  end
end

wait_for.each(&:join)
counter.to_i # => 20
```

Farce also aims to be fast and efficient, with performance ranging from minimal overhead to outperforming other options.

It does so by choosing the best implementation for the situation. The counter in the above example will use Java's `AtomicLong` on JRuby and TruffleRuby in GraalVM mode, an `AtomicReference` on TruffleRuby in native mode, and an atomic, native counter on CRuby, so it runs without having to use any locks on any of these platforms.

This is especially useful when coordinating work between Fiber schedulers and Ractors:

```ruby
queue = Farce::Queue.new

# Background ractor pushing work into the queue
# This would not work with Ruby's built-in Queue
Ractor.new(queue) do |queue|
  loop { queue.push expensive_work }
end

# This would not work with Ratomic::Queue
Async do
  # Task waiting for work from the queue
  Async { loop { do_something queue.pop  } }

  # Doesn't get blocked by the other task waiting for the queue
  Async { unrelated_work }
end
```

## Features

### Data Structures

Farce provides a range of data structures that are ractor-safe, mutable, and expose high-level concurrency APIs in addition to standard Ruby APIs for the built-in classes it offers replacements for.

#### Maps

Maps are Hash-like key-value data structures. They do not preserve insertion order.

They implement almost all methods Ruby's Hash offers:

```ruby
map       = Farce::Map.new
map[:foo] = :bar

map.merge! answer: 42
map.transform_values! { -it.to_s }
map.to_h # => {answer: "42", foo: "bar"}
```

In addition, they come with a range of [atomic operations](#atomic-operations), and have built-in key normalization support:

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
* `LeaseMap` manages [leases](#leases) associated with known keys.
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

#### Vectors

`Farce::Vector` is to `Array` what `Farce::Map` is to `Hash`. It implements the same interface, with additional atomic operations.

```ruby
list = Farce::Vector.new
10.times { list << it }
list.to_a # => [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
list.sum  # => 45
```

#### Sets

`Farce::Set` is to `Set` what `Farce::Map` is to `Hash`. It implements the same interface, with additional atomic operations.

```ruby
jobs = Farce::Set[:compile, :test]
jobs.add? :publish    # => jobs
jobs.add? :test       # => nil
job.include? :publish # => true
```

Besides the standard set implementation, Farce includes two specialized sets:

* `SortedSet` keeps its entries in order based on value comparison.
* `WeakSet` only holds weak references to its entries.

#### Atoms

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

#### Counters

Ractor-shareable, atomic counter. This is a stateful, numeric object.

It is similar to creating an [atom](#atoms) for an integer, but significantly faster, as it will use a truly lock-free implementation on most CPU/Ruby combinations.

```ruby
counter = Farce::Counter.new
counter.value # => 0

# Increase the counter by 1
counter.increment
counter.value # => 1

# Increase the counter by 5 on another Ractor
Ractor.new(counter) { it.add(5) }

# Give the other ractor time to run
sleep 0.1

counter.value # => 6
```

#### Flags

Ractor-shareable, atomic boolean.

Just like Counter for Integer, this is similar to creating an [atom](#atoms) for a boolean, but significantly faster, as it will use a truly lock-free implementation on most CPU/Ruby combinations.

```ruby
flag = Farce::Flag.new(true)
flag.value # => true
```

#### References

Atoms, as well as other value objects, like counters and flags, can be wrapped in a reference object, which delegates all methods to the given atom for convenience:

```ruby
atom = Farce::Atom.new(42)
ref  = Farce::Reference.new(atom)

ref.to_s  # => "42"
ref > 10  # => true

atom.value = :foo
ref.to_s  # => "foo"
```

#### Molecules

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

#### Queues

`Farce::Queue` is a drop-in replacement for Ruby's `Queue` and `SizedQueue`. It provides a blocking and a non-blocking API.

```ruby
queue = Farce::Queue.new
queue.push(:ok)
queue.pop     # => :ok
queue.try_pop # => nil
```

Queues provide additional features over Ruby's queue:
* Like the rest of Farce, they work with Ractors (implementing [sharing modes](#sharing-modes) for their [default variant](#variants-and-scopes)).
* In addition to closing, they allow sealing, which prevents pushes but still allows pulling from the queue until it has been drained.
* They have an API to wait for them to be ready for a push or pull based on capacity without actually adding or removing values.
* They can optionally monitor how long the oldest item has been sitting in the queue (which is great for building auto-scaling on top of the queue).

The [strict variant](#available-variants) has comparable performance to `SizedQueue`, while the default variant pays a fixed overhead for [handling unshareable data](#sharing-unshareable-data). Both variants outperform other third-party, Ractor-shareable queues (none of which are Fiber scheduler compatible, which Farce's queues are).

##### Priority Queues

In addition to normal queues, which are FIFO, Farce also offers a `PriorityQueue`, where values are removed from the queue in order of priority instead of insertion order:

```ruby
# use order: :descending to reverse priorities
queue = Farce::PriorityQueue.new

queue.push :a, priority: 2
queue.push :b, priority: 1

queue.pop # => :b
```

##### Timer Queues

Timer queues are similar to priority queues, sorted by float values, but these values are timestamps (based on [Farce::Clock](#additional-classes), not on Ruby's Time, which isn't monotonic). Any `pull` will block until the next timestamp has been reached.

```ruby
queue = Farce::TimerQueue.new
queue.push(:ok, in: 1.5)

# blocks for ~1.5 seconds
queue.pop # => :ok
```

Timer queues are useful for implementing schedulers (which is what Farce uses them for under the hood), so they have one additional feature: You can delete an entry if you know its timestamp.

```ruby
queue     = Farce::TimerQueue.new
timestamp = Farce.clock(in: 0.2)

queue.push(:first,  at: timestamp - 0.1)
queue.push(:second, at: timestamp)
queue.push(:third,  at: timestamp + 0.1)

queue.delete(:second, at: timestamp)

result = []
result << queue.pop until queue.empty?
result # => [:first, :third]
```

##### Queue capacity

Queues support setting a maximum capacity. If the capacity has been reached it will block any pushes to create back pressure.

```ruby
queue = Farce::Queue.new(2)

queue.try_push(:a) # => true
queue.try_push(:b) # => true
queue.try_push(:c) # => false
```

Normal queues have a default capacity of 1024. You can explicitly set the capacity to `nil` to create an unbounded queue.
Priority queues and timer queues do not have a default capacity, so earlier entries are not getting blocked unexpectedly.

### Shims, Polyfills, and Extensions

#### Ractor

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

#### Port

Farce includes `Farce::Port`, which is either an extended subclass of `Ractor::Port` if it is available, or a polyfill if it isn't.

In addition to `Ractor::Port` it supports the following features:
* [Sharing modes](#sharing-modes) both for `.new` and `#send`.
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

#### WeakRef

`Farce::WeakRef` is a drop-in replacement for Ruby's [`WeakRef`](https://docs.ruby-lang.org/en/4.0/WeakRef.html), which at the time of writing cannot be used outside of the main Ractor at all.

Farce implements a version based on weak [atoms](#atoms). Not only can it be used on non-main Ractors, `Farce::WeakRef` instances themselves are Ractor-shareable if the value they reference is also Ractor-shareable (or has been garbage collected). Moreover, calling `Ractor.make_shareable(weak_ref)` will propagate through to the referenced value.

#### Resolv

`Farce::Resolv` is a version of Ruby's [`Resolv`](https://docs.ruby-lang.org/en/4.0/Resolv.html), using [counters](#counters) instead of a global instance variable, and can therefore be used outside the main Ractor.

### Sharing Unshareable Data

Ruby's `Ractor::Port#send` and related methods share Ruby objects between Ractors with this logic:

1. If the object is Ractor shareable, pass it by reference.
2. If the object isn't Ractor shareable and the `move` option hasn't been set to `true`, pass it by value (copy it).
3. Otherwise move it from the sending Ractor to the receiving Ractor, invalidating any previous references.

This is a great start but has some complications:
* Copying can lead to a lot of data duplication, as large object trees may be copied between Ractors over and over again.
* Moving may invalidate nested references unexpectedly, breaking code in the sending Ractor.
* If you want to prevent sending unshareable objects to other Ractors, you have to manually check them every time.

Farce has mechanisms and tools to improve the situation.

#### Sharing Modes

> [!TIP]
> Learn more in the dedicated  [modes documentation](docs/modes.md).

The [default variants](#variants-and-scopes) of most [data structures](#data-structures), as well as [`Farce::Port`](#port), implement a range of sharing modes, typically as a keyword argument for initialization as well as for methods that modify their content.

These modes are:

| Mode              | What happens to non-shareable data                                                   | A typical use                               |
| ----------------- | ------------------------------------------------------------------------------------ | ------------------------------------------- |
| `:copy` (default) | Transfers a copy and leaves the original usable. This is the default.                | Send a snapshot of a request.               |
| `:move`           | Transfers ownership and makes the original inaccessible.                             | Hand a completed batch to a consumer.       |
| `:local`          | Keeps the same object in its originating Ractor.                                     | Pass work between local threads or fibers.  |
| `:make_shareable` | Calls `Ractor.make_shareable` on the original.                                       | Publish finished configuration.             |
| `:mutable`        | Copies non-shareable objects into a [`Farce::Mutable`](#mutables).                   | Synchronize mutations across Ractors.       |
| `:shareable_copy` | Makes a shareable copy and leaves the original alone.                                | Publish a snapshot of an editable document. |
| `:dedup`          | Deduplicates the value, then makes it shareable. May update and freeze the original. | Reuse repeated message contents.            |
| `:proxy`          | Creates a [`Farce::Proxy`](#proxies) that executes calls in the original Ractor.     | Share access to a mutable object.           |
| `:raise`          | Raises `Ractor::IsolationError`.                                                     | Enforce a shareable-data boundary.          |

Here's an example:

```ruby
map = Farce::Map.new(mode: :mutable)
map[:content] = "Hi there!"

Ractor.new(map) { it[:content] << " How are you doing?" }.join

# Hi there! How are you doing?
puts map[:content]
```

#### Envelopes

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

#### Mutables

Mutables are special wrappers for Ruby objects that are Ractor-shareable when frozen but can be modified when not.

```ruby
mutable = Farce::Mutable.new("content")
Ractor.new(mutable) { it << " & additional content" }.join
mutable # => #<Farce::Mutable[String] "content & additional content">
```

They expose a mutable API by keeping a frozen snapshot of the wrapped object, atomically unfreezing, mutating, and freezing it whenever a method otherwise throws a `FrozenError`. This means non-mutating methods have almost no additional cost, and in contrast to [proxies](#proxies), method calls do not have to be dispatched across Ractors, even when modifying the object. However, mutating methods will copy the wrapped object's content. This may be fine, but could be expensive when used repeatedly on large objects.

#### Proxies

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

#### Mode Managers

You can use a mode manager if you want to support sharing modes for a custom object.

The mode manager might wrap objects in an envelope. It also exposes a method to unwrap objects again, which will only do so for envelopes created by the specific mode manager. That's why we were able to pass an envelope through the queue in the [example above](#sharing-modes) without it getting opened automatically.

```ruby
manager = Farce::ModeManager.new(mode: :move)
payload = ["inside a mutable array"]
Ractor.shareable?(payload) # => false

shareable = manager.wrap(payload) # => #<Farce::Envelope::Move>
Ractor.shareable?(shareable) # => true

payload = shareable.value
Ractor.shareable?(payload) # => false
```

#### Leases

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

At first glance, this looks just like a [map](#maps) of `Lease` instances. And it pretty much is, except it has some nice tooling on top of it, where it can automatically check values out and back in:

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

### Variants and Scopes

Many classes, including all [data structures](#data-structures), implement multiple variants as separate subclasses within module namespaces.

`Farce::Map`, `Farce::Strict::Map`, `Farce::Local::Map`, and `Farce::Unshared::Map` all support the same API, except that:

* `Farce::Map` accepts an optional `mode` keyword for its initializer and many methods.
* `Farce::Strict::Map` will not allow any non-shareable data to be stored in it. It is slightly faster than `Farce::Map`.
* `Farce::Local::Map` will accept an optional `scope`  keyword for its initializer, and will have different content for each [scope](#provided-scopes).
* `Farce::Unshared::Map` cannot be shared across Ractors, but in turn can store any Ruby object directly, including unshareable objects. It is as fast as `Farce::Strict::Map`.

#### Available Variants

> [!TIP]
> Learn more in the dedicated [variants documentation](docs/variants.md).

These variants are provided by Farce:

1. **Default** variants, under the `Farce` namespace:
   * Can **store unshareable values**, usually via [modes](#sharing-modes).
     For maps, this is only supported for values. Keys must be shareable.
   * Instances are **Ractor-shareable**.
   * The data structure is **thread-safe**.
2. **Strict** variants, under the `Farce::Strict` namespace:
   * **Forbid unshareable values**
   * Instances are **Ractor-shareable**.
   * The data structure is **thread-safe**.
   * May provide performance benefits over the default variant.
3. **Local** variants, under the `Farce::Local` namespace:
   * Will have **different content** for each [scope](#provided-scopes).
   * Can **store unshareable values**, including unshareable map keys.
   * Instances are **Ractor-shareable**.
   * The data structure is **thread-safe**.
4. **Unshared** variants, under `Farce::Unshared` namespace:
   * Can **store unshareable values**, including unshareable map keys.
   * Instances are **<u>not</u> Ractor-shareable**.
   * The data structure is **thread-safe**.
   * May provide performance benefits over the default variant.
5. **Unsafe** variants, under `Farce::Unsafe` namespace:
   * Same as Unshared, except they do **<u>not</u> guarantee thread-safety**
   * May provide performance benefits over all other variants.
6. **Transaction** variants, under `Farce::Transaction` namespace:
   * Created as mirrors of another object within a [transaction](#transactions).
   * Should not be shared across transaction boundaries.
   * Should not be initialized directly.

The following is true for all variants:
* Blocking operations will suspend a non-blocking fiber, but not block the underlying scheduler.
* The return value of `frozen?` will correctly reflect whether an instance is mutable or not.

However, keep the following in mind:
* Not all classes implement all variants. Check out the [full list](docs/variants.md#classes-implementing-variants)
* Other classes that don't implement variants are also nested under the `Farce` namespace.

#### Provided scopes

> [!TIP]
> Learn more in the dedicated [scopes documentation](docs/scopes.md).

Local variants support scopes:

```ruby
map      = Farce::Map.new(scope: :thread)
map[:id] = 1

Thread.new do
  map[:id] = 2
  map[:id] # => 2
end.join

map[:id] # => 1
```

The following scopes are available:

 | Scope              | Description                                                                                      |
 | ------------------ | ------------------------------------------------------------------------------------------------ |
 | `ractor` (default) | Content varies by [Ractor](https://docs.ruby-lang.org/en/4.0/Ractor.html)                        |
 | `thread_group`     | Content varies by [ThreadGroup](https://docs.ruby-lang.org/en/4.0/ThreadGroup.html)              |
 | `thread`           | Content varies by [Thread](https://docs.ruby-lang.org/en/4.0/Thread.html)                        |
 | `fiber_storage`    | Content varies by [Fiber storage](https://docs.ruby-lang.org/en/4.0/Fiber.html#method-i-storage) |
 | `fiber`            | Content varies by [Fiber](https://docs.ruby-lang.org/en/4.0/Fiber.html)                          |

Fiber storage is typically inherited by a blocking fiber from the fiber creating it.

### Concurrency

Farce is built for concurrent and parallel code execution.

#### Locks

Farce ships with two lock classes:
* `Lock` is a drop-in replacement for Ruby's `Mutex`.
* `ReadWriteLock` exposes `with_read_lock`/`with_write_lock` to allow multiple concurrent reads, but exclusive write access.
  
However, Farce exposes many APIs to eliminate the need for locks altogether.

#### Atomic Operations

Farce's [data structures](#data-structures) all expose a range of methods for atomic operations:

```ruby
# A Hash-like object
map = Farce::Map.new

# Atomically store something for :key if it hasn't been set
map.store_if_absent(:key) { "initial value" }

# Atomically update :key
map.update(:key, &:upcase)

# An Array-like object
list = Farce::Vector.new
list[0] = 42

# Atomically replace list[0] with 256 if the value is still 42
list.compare_and_set(0, 42, 256)
```

#### Observability and Signaling

All the [data structures](#data-structures) come with extra observability methods, which eliminate the need for using [condition variables](https://docs.ruby-lang.org/en/4.0/Thread/ConditionVariable.html) and [mutexes](https://docs.ruby-lang.org/en/4.0/Thread/Mutex.html).

Even setting aside that these don't work across ractors, this drastically reduces the risk of race conditions (very easy to do if you <u>don't</u> use the same mutex everywhere) or blocking code you don't need to block (very easy to do if you <u>do</u> use the same mutex everywhere).

So instead of sharing locks you can simply wait for a change to happen!

```ruby
# block until the stored value for :key is greater than 10
map.wait_until(:key) { it > 10 }

# block until the value for an atom is no longer :initial
map.wait_until_changed(:initial)

# block until a counter has reached at least 20
counter.wait_while_below(20)
```

If these conditions are met right away, these never block.

But what about more complex conditions, involving multiple variables, or objects from other libraries that don't implement similar methods? No need to reach for a lock! You can use a Signal!

```ruby
signal  = Farce::Signal.new
target  = 100
counter = Farce::Counter.new

# A Thread that keeps reducing the target value every 20 milliseconds
Thread.new do
  while target.positive?
    sleep 0.02
    target -= 1
    signal.broadcast # notify everyone else
  end
end

# A Ractor that counts up in 10 millisecond intervals
Ractor.new(counter, signal) do |counter, signal|
  while counter < 100
    sleep 0.01
    counter.increment
    signal.broadcast # notify everyone else
  end
end

# wait until the counter is at or above the target
signal.wait_until { counter >= target }
```

#### Transactions

This all sounds great. But you still might want to reach for a lock if you want to modify more than one data structure, if their state is tightly coupled (i.e., updating one without yet updating the other would leave your code in an invalid state).

And a lock is an acceptable solution here. Again, you might want to wrap all the read access in a lock, as there will still be an invalid state. And you also want to roll back any changes already made while holding the lock, if an exception occurs. That is the standard approach in a lot of Ruby code.

Farce offers an alternative. It implements [STM-style transactions](https://en.wikipedia.org/wiki/Software_transactional_memory). You supply a block of code that makes changes to multiple data structures. These changes are only written to these data structures in a commit phase after the block finishes, and they either all succeed or all fail, and they only succeed if the values you've read from any of these data structures haven't changed.

Otherwise the block is rerun.

And this isn't limited to special `TVar` containers, like the APIs provided by concurrent-ruby or ractor-sharing. It supports Farce's main data structures, including [maps](#maps), [vectors](#vectors), [sets](#sets), [atoms](#atoms), and [molecules](#molecules). Moreover, it also supports [mutables](#mutables), meaning you can turn most Ruby objects into something transaction compatible fairly easily!

In contrast to other implementations mentioned above, there is no implicit tracking. You need to explicitly add an object to a transaction. This also avoids any uncertainty around nested transactions and unexpected rollbacks.

```ruby
accounts = Farce::Map.new({a: 100, b: 200})

# transfer 80 from :a to :b, but only if both succeed
success = Farce.transaction(accounts) do |tx, accounts|
  tx.abort! if accounts[:b] < 80
  accounts[:a] += 80
  accounts[:b] -= 80
end

if success
  puts "Transaction succeeded"
else
  puts "Transaction failed"
end
```

In the above example, `accounts` was added to the transaction right away. But you can also add new objects to the transaction programmatically by calling `tx[object]`. All reads and writes need to happen through the wrapper object returned by that call (or passed to the block).

##### Maps and Sets

Maps and sets use fine-grained transaction tracking. In the above example, if accounts had another entry, `:c`, its value changing would not impact the transaction at all.

Similarly, if your transaction uses `Transaction::Map#size` as input, only a change in size would trigger a rerun, not a change in content.

This is ideal for scenarios where you use maps as a general data store and sets to track whether an operation was performed on an object (a common pattern to prevent infinite recursion).

##### TVars

Farce doesn't come with a `TVar` class. You can just use an [atom](#atoms) instead.

But it does come with built-in support for [`Concurrent::TVar`](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/TVar.html) and [`Ractor::TVar`](https://github.com/ko1/ractor-sharing/blob/main/docs/tvar.md) (assuming you also load these libraries, see [integrations](#integrations)).

```ruby
tvar = Concurrent::TVar.new(50)
map  = Farce::Map.new({a: 100, b: 200})

Farce.transaction(map, tvar) do |map, tvar|
  # subtract tvar's value from a and b, then set tvar to 0
  # no invalid in-between state is ever visible to anything outside of this transaction
  map[:a] -= tvar.value
  map[:b] -= tvar.value
  tvar.value = 0
end
```

### Scheduling Code

Farce offers built-in code scheduling support.

#### `Farce.on_main`

Some code has to be executed on the main Ractor, especially when working with legacy code that doesn't support Ractors.

You can pass a block to `Farce.on_main` to run code on the main Ractor. The method call will block until the code has been executed.

```ruby
# most of concurrent-ruby is not usable outside of the main-ractor
$tvar = Concurrent::TVar

# let's run computation outside of the main ractor
Ractor.new do
  value = compute_expensive_value

  # need to report back to the main ractor
  Farce.on_main(value) { $tvar.value = it }
end
```

Sometimes you don't need to wait for the code to be done running on the main Ractor. In such cases, you can use `schedule`, as `on_main` returns a [scheduler](#schedulers) instance when called without a block:

```ruby
Ractor.new do
  Farce.on_main.schedule do
    sleep 1
    puts "Hello from the main Ractor"
  end
  puts "Hello from the nested Ractor"
end

sleep 1.1
```

#### `Farce.in_parallel`

As you can see in the [very first example](#farce-fiber-and-ractor-compatibility-enabler), creating Ractors ad hoc because you want to run something in parallel is quite expensive.

Farce offers `Farce.in_parallel` instead, which will manage a [Ractor Pool](#ractor-pools), starting new ractors if the current ones cannot keep up with the current load (but at most as many as the system's CPU cores). It also shuts unused Ractors down again after some inactivity.

```ruby
input = "this is my input"
Farce.in_parallel(input) { expensive_computation(it) }
```

Like most of Farce, this is completely opt-in. If you never use this feature, no pool is being set up and no extra Ractors are created.

#### `Farce.schedule`

`Farce.in_parallel` might not always be what you want. Maybe you are working on a library and don't want to dictate a concurrency model?

You can use `Farce.schedule`, which will automatically figure out how to run code off-band. You can use `mode: local` to force execution inside the current Ractor (which it will prefer by default if there already is some scheduler running, but not enforce).

```ruby
# just run this asynchronously, don't care how
Farce.schedule("hello") { |message| puts message.upcase }
```

"Some scheduler?" you might say? Some scheduler! It will automatically detect if there is a local scheduler. This can either be a Fiber scheduler, like [async](https://socketry.github.io/async/) or [Carbon Fiber](https://yaroslav.io/opensource/carbon_fiber), or an internal scheduler created by Farce:

```ruby
Async do
  # this is basically the same as calling Async { do_something }
  Farce.schedule { do_something }
end
```

#### Schedulers

You can create your own `Farce::Scheduler`, running on a dedicated Ractor:

```ruby
scheduler = Farce::Scheduler.create
scheduler.schedule("hello") { |message| puts message }
scheduler.close # we're done, shut it down
```

Or you can set one up as a Fiber scheduler for the current Thread:

```ruby
scheduler = Farce::Scheduler.new
Fiber.set_scheduler(scheduler)
Fiber.schedule { puts "Hello from the scheduler!" }
```

Scheduler instances are Ractor-shareable.

#### Ractor Pools

`Farce::Pool` implements the same scheduling interface, but manages a pool of Ractors. This is what [`in_parallel`](#farcein_parallel) uses under the hood.

```ruby
# At least two Ractors, up to four. Launch a new one if a task waits longer than 100 milliseconds.
pool = Farce::Pool.new(min_size: 4, max_size: 10, grow_after: 0.1)
pool.schedule { puts "Hello from the pool!" }
```

#### Third-Party Fiber Schedulers

Both `Farce::Scheduler` and `Farce::Pool` run a Fiber scheduler under the hood to execute tasks. This is a Farce-internal scheduler by default, but you can replace it with your own if you want:

```ruby
# Use the fiber scheduler from the carbon_fiber gem.
pool = Farce::Pool.new { CarbonFiber::Scheduler.new }
pool.schedule { puts "⚡️ Running Carbon Fiber on a pool of Ractors! ⚡️" }
```

You can also use a different fiber scheduler as the default (in which case it will be picked up by `in_parallel` and `on_main` as well) by setting the `FARCE_FIBER_SCHEDULER` environment variable or using the `fiber_scheduler` configuration setting:

```ruby
# This needs to happen before the first scheduler call.
Farce.configure do |config|
  config.fiber_scheduler = :carbon_fiber

  # or, alternatively:
  config.fiber_scheduler { CarbonFiber::Scheduler.new }
end

Farce.in_parallel do
  Fiber.scheduler.class # => CarbonFiber::Scheduler
end
```

If a string or symbol is provided (like `carbon_fiber`), it will first resolve this to a constant (i.e., `CarbonFiber`). If that constant is a class, it will use that for creating the fiber scheduler. If it is a module, it will look for a `Scheduler` constant inside it, which matches the established pattern implemented by most gems, including `farce`, `async`, `carbon_fiber`, `libev_scheduler` (use `libev` as value), `itsi_scheduler` (use `itsi` as value), but it also works for gems that define their scheduler class at top level, like `fiber_scheduler`.

Note that most of these are outdated and don't work with any recent Ruby version, with the notable exception of `async` and `carbon_fiber`.

### Integrations

Farce ships with a couple of integrations that are automatically loaded if and only if both farce and the other gem have also been loaded (it does not automatically load these gems, even if they are part of the current bundle). This is load-order independent.

#### Active Support

The Active Support integration adds the following methods:

* For all data structures: `as_json`, `blank?`, `deep_dup`, and `duplicable?`
* For maps: `assert_valid_keys`, `compact_blank`, `reverse_merge`, `stringify_keys`, `symbolize_keys`, `to_param`, `to_query`, `with_defaults`, and `with_indifferent_access`
* For vectors: `compact_blank`, `excluding`, `from`, `including`, `inquiry`, `in_groups`, `in_groups_of`, `in_order_of`, `maximum`, `minimum`, `pluck`, `pick`, `split`, `to`, `to_fs`, `to_param`, `to_sentence`, `to_query`, `to_xml`, `second`, `third`, `fourth`, `fifth`, `forty_two`, `third_to_last`, and `second_to_last`

And the following features:
* Converting `ActiveSupport::HashWithIndifferentAccess` to a map via [`Farce.enfarce`](#top-level-methods) will set up the correct key normalization.
* [`Farce::Clock`](#additional-classes) understands `ActiveSupport::Duration`.

Other methods are already being inherited by various objects via `Object`, `Enumerable` for vectors, sets, and maps, `Numeric` for counters, etc.

```ruby
require "active_support/all"
require "farce"

map     = Farce::Map.new.with_indifferent_access
map[:a] = 10

map.blank? # => false
map["a"]   # => 10
```

The integration isn't triggered by loading `active_support`, but instead looks for `active_support/core_ext`, so you should require that (or `active_support/all`, which in turn requires it).

#### Dry Types

Adds support for Farce [data structures](#data-structures) to [Dry Types](https://hanakai.org/learn/dry/dry-types):

```ruby
require "dry-types"
require "farce"

module Types
  include Dry.Types()
  include Farce.DryTypes()

  IntegerVector = Vector.of(Coercible::Integer)
end

numbers = Types::IntegerVector[["1", 2]]
numbers.class # => Farce::Vector
numbers.to_a  # => [1, 2]
```

Check out the [dedicated documentation](docs/gems/dry-types.md) to learn more.

#### JSON, YAML, etc

It ships integrations for serialization (and some deserialization) with the following gems:

* For BSON support: `bson`
* For CBOR support: `cbor`
* For JSON support: `json` (from the Ruby standard library), `oj`, and `yajl`
* For MessagePack: `msgpack` – see the [detailed documentation](docs/gems/msgpack.md)
* For YAML: `psych` (from the Ruby standard library)

Example:

```ruby
require "json"
require "farce"

map = Farce::Map.new
map[:x] = Farce::Vector[1, 2, 3]
map.to_json # => '{"x":[1,2,3]}'
```

#### Concurrent Ruby

The integration adds the following features if [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) has been loaded:

* [Transaction support for `Concurrent::TVar`](#tvars)
* Automatic conversion of `Concurrent::Map` instances to [maps](#maps) via [`Farce.enfarce`](#top-level-methods).

#### Ractor Sharing

The integration adds the following features if [ractor-sharing](https://github.com/ko1/ractor-sharing) has been loaded:

* [Transaction support for `Ractor::TVar`](#tvars)
* Support for traversing and deep freezing `Ractor::TVar`, `Ractor::LockVar`, `Ractor::LockHash`, and `Ractor::KeyLockHash`
* Support for converting `Ractor::LockHash` and `Ractor::KeyLockHash` to [maps](#maps) via [`Farce.enfarce`](#top-level-methods).

#### Additional Integrations

* [`sorted_set`](https://github.com/knu/sorted_set): Add support for walking and converting them.
* [`ractor-tmvar`](https://github.com/yoshitsugu/ractor-tmvar): Adds transaction support.
* [`weakref`](https://github.com/ruby/weakref): Add support for walking and converting them.

#### Disable Automatic loading

You can set the environment variable `FARCE_AUTOLOAD_INTEGRATIONS` to `false` or `0` to disable automatic integration loading.

Or you can use `Farce.configure` to disable it. But you may have to do so before loading `farce` unless you're absolutely certain the other gem has not yet been loaded:

```ruby
# This could go in an initializer
require "farce/config"

Farce.configure do |config|
  config.autoload_integrations = false
end

require "farce"

# you now need to load any integrations you might want explicitly
# these are available via "farce/integrations/#{gem_name}"
require "farce/integrations/json"
require "farce/integrations/concurrent"
```

### Miscellaneous

#### Top Level Methods

* `Farce.clock` returns the monotonic clock time in seconds as a Float.
* `Farce.config` returns the global configuration object.
* `Farce.configure` allows you to configure Farce.
* `Farce.dedup` de-duplicates the given object based on a deduplication cache shared by all Ractors.
* `Farce.enfarce` turns a vanilla data structure into its Farce equivalent.
* `Farce.freeze_graph` recursively freezes an object graph.
* `Farce.in_parallel`, `Farce.on_main`, and `Farce.schedule`, see [Scheduling Code](#scheduling-code)
* `Farce.rebind` rebinds a proc or lambda while preserving its Ractor-shareability.
* `Farce.transaction` creates and runs a [transaction](#transactions).

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
rebound.call(18) # => 50
```

#### Additional Classes

Other classes Farce provides include:
* `Config`: Configuration class, see [Third-Party Fiber Schedulers](#third-party-fiber-schedulers) example.
* `ClassMirror`: inheritance-aware registry for classes
* `Clock`: Timing functions based on a monotonic clock rather than on `Time`.
* `Deduper`: Create your own deduplication cache. Direct usage isn't recommended, use [`Farce.dedup`](#top-level-methods) instead.
* `Exchanger`: A synchronization point for two-way data swapping between Threads, Ractors, and/or Fibers. Drop-in replacement for concurrent-ruby's exchanger.
* `Lazy`: Lazily initialized value.
* `LazyRef`: A [reference](#references) for a lazily initialized value.
* `ThreadScheduler`: An alternative [scheduler](#scheduling-code) creating a new thread for each unit of work. Used on TruffleRuby.
* `Walker`: A tool for walking a Ruby object tree.
* `WeakValue`: A value object version of [`WeakRef`](#weakref). Allows handling references more explicitly, without automatic method delegation.

In addition, Farce includes a range of error classes not listed here. Check the [API documentation](https://rkh.github.io/farce/) or [code base](lib/farce/error.rb) for these.

#### Shareability Mixins

Farce includes mixins to help you make your custom classes shareable:

* `Shareable` automatically marks objects as shareable (via `Ractor.make_shareable`) after initialization.
* `Shareable::Delegated` delegates `freeze` and `frozen?` to another object holding your object's state.
* `Shareable::Immutable` instances are always immutable, being frozen after initialization.
* `Shareable::Native` is for objects implemented in a native extension, which allows setting the frozen and shareable state separately.
* `Shareable::Tracked` for objects implementing frozen tracking (via an internal [flag](#flags)).
* `Shareable::Unfreezable` for objects that cannot be frozen (like [queues](#queues)).

And also mixins to prevent them from being shareable:

* `Unshareable`: Instances aren't shareable and cannot be made shareable. By default, they also cannot be copied or moved between Ractors.
* `Unshareable::Copyable`: Instances aren't shareable but may be copied to another Ractor.
* `Unshareable::Movable`: Instances aren't shareable but may be moved to another Ractor.

`Unshareable::Copyable` and `Unshareable::Movable` may be combined.

#### Constants

* `Farce::MODES`: List of supported [sharing modes](#sharing-modes).
* `Farce::SCOPES`: List of [provided scopes](#provided-scopes).
* `Farce::VERSION`: The current version.

## Compatibility and Dependencies

Farce has no mandatory dependencies beyond Ruby itself.

### Ruby

Each Farce release is expected to be compatible with:

* The [latest patch release](https://www.ruby-lang.org/en/downloads/releases/) for each [CRuby](https://www.ruby-lang.org/en/) version [still receiving bug fixes](https://www.ruby-lang.org/en/downloads/branches/).
* Ruby's [master branch](https://github.com/ruby/ruby/tree/master) at the time of release (i.e., the upcoming major version of CRuby).
* The latest stable release of [JRuby](https://www.jruby.org/) and [TruffleRuby](https://truffleruby.dev/) (both in native and GraalVM modes).

Moreover:

* Dropping support for a CRuby version is only done in major releases.
* If support for an older CRuby version is dropped, Farce will still backport security fixes for at least as long as that CRuby version is [still receiving security fixes](https://www.ruby-lang.org/en/downloads/branches/).

### Optional Dependencies

Farce's optional [integrations](#integrations) depend on external libraries. Automated tests only run against recent versions of these libraries, but the code is written to be compatible with as wide a range as possible.

Farce should be compatible with these versions:

| Gem               | Minimum Version | Release Date |
|-------------------|-----------------|--------------|
| `ractor-tmvar`    | 0.3.0           | 2026-10-06   |
| `msgpack`         | 1.7.0           | 2023-03-29   |
| `concurrent-ruby` | 1.1.8           | 2021-01-20   |
| `dry-types`       | 1.0.0           | 2019-04-23   |
| `activesupport`   | 5.1.0           | 2017-04-27   |
| `oj`              | 2.8.1           | 2014-04-21   |
| `bson`            | 2.0.0           | 2013-12-02   |
| `psych`           | 1.1.0           | 2011-03-30   |

Any version of `cbor`, `json`, `ractor-sharing`, `sorted_set`, and `weakref` should be supported

If you want to use any of these in a version that is incompatible with Farce, you can [disable automatic integration loading](#disable-automatic-loading).

### Similar Projects

* [ractor-shim](https://github.com/eregon/ractor-shim/) provides similar functionality to `Farce::Ractor`. See [the comparison document](docs/gems/ractor-shim.md) for more details.
* [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) provides a more complete set of concurrency primitives than Farce, but is not compatible with Ractors.
* [ratomic](https://mperham.github.io/ratomic/) has overlapping functionality with Farce for basic data structures like maps, counters, and queues.
* [ractor_safe](https://github.com/jhawthorn/ractor_safe/) has overlapping functionality with Farce for basic data structures like maps, counters, and queues.
* [ractor-sharing](https://github.com/ko1/ractor-sharing) has overlapping functionality with Farce for basic data structures like maps, counters, queues, as well as software transactional memory.

All of the above projects can safely be used alongside Farce in the same application.

## Installation

### Globally

To install Farce globally, you can use the following command:

```console
$ gem install farce
```

### As a project dependency

If you want to use Farce directly in your project, it is recommended to do so via [Bundler](https://bundler.io).
Add Farce to your `Gemfile`:

```ruby
source "https://gem.coop" # or "https://rubygems.org"

gem "farce"
```

Then run `bundle install` to install the dependencies.

### As a library dependency

Farce's main purpose is to be used as a dependency for other libraries. As such, it will most commonly be added as a [runtime dependency](https://guides.rubygems.org/specification-reference/#add_dependency) to your gemspec:

```ruby
Gem::Specification.new do |spec|
  # ...
  spec.add_dependency "farce"
end
```

### Local setup

If you want to work on Farce itself, you can clone the repository and use [mise](https://mise.jdx.dev) to set everything up:

For more details, or if you aren't using mise, check the [contribution guidelines](CONTRIBUTING.md).

```console
$ git clone https://github.com/rkh/farce.git # prefix with `jj` if you're using Jujutsu
$ cd farce
$ mise run
```

### Loading Farce
You should always require `farce`, rather than any other files in `lib`. Other files are not intended as entry points.

```ruby
require "farce"
```

Constants (classes, modules, etc.) under the `Farce` namespace are loaded lazily (thread- and ractor-safe), so there is no
need to specifically load any particular file.

## Known Issues and Limitations

### Possible discrepancy regarding frozen state in Ruby and C

> I agree that **freezing means the object's own state is immutable**, not just its instance variables, so we should not freeze [*shareable, mutable object*]. Forbidding instance variables on them is the right approach. [...] **A shareable object that is not frozen never has instance variables**. This should also hold when C extensions define such objects in the future.
> — *Yukihiro Matsumoto* (Ruby Issue [#22291](https://bugs.ruby-lang.org/issues/22291#note-4), emphasis added)

In Ruby, Farce objects reflect their frozen state accurately. If a map returns `true` for `frozen?`, you cannot add, remove, or replace its entries.

There are some technical challenges implementing this behavior: From within Ruby, you cannot mark an object as Ractor shareable without freezing it first. This is possible from a C-extension, but then instance variables can no longer be used, so state tracking needs to happen purely at the C level or outside of the Ruby object.

To work around this, Farce follows a hybrid approach, marking objects with state purely defined in a C extension as Ractor shareable without freezing them, and reimplementing freezing behavior in Ruby for objects where this isn't safely possible.

This means:

* `frozen?` and `freeze` will behave as expected for all Farce classes.
* `Kernel.instance_method(:frozen?).bind_call(object)` might report a different value from `object.frozen?`
* C-level checks for frozen state, such as `RB_OBJ_FROZEN`, might differ from what Ruby-level methods report.

## Housekeeping

Farce follows [Semantic Versioning](https://semver.org/) and [the RubyGems versioning policy](https://guides.rubygems.org/patterns/#versioning). Farce's original code is released under the [MIT License](MIT-LICENSE). Native builds also contain Kazlib 1.20-derived `dict.c` and `dict.h`; their original permissive license and copyright notice are retained in those files. The native gem therefore declares `MIT` and `LicenseRef-Kazlib-1.20`, while the pure-Java gem declares only `MIT` because it does not ship Kazlib.

Built with love in Berlin, by Konstantin Haase.
