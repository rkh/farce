<!--
# @title Introduction
-->

# Introduction

Ruby 3.0 introduced two powerful concurrency primitives: **Fiber schedulers** and **Ractors**, besides the already existing **Threads**:

* **Threads** are the classic concurrency primitive in Ruby, and mostly map to native operating system threads. This way any system calls, IO, or other blocking operations will block a thread, allowing another one to run. However, on the official Ruby implementation (often referred to as CRuby or MRI), Threads cannot run in parallel due to the Global VM Lock (GVL). This means that even if you have multiple threads, only one of them can execute Ruby code at a time.
* **Ractors** provide parallelism, even on CRuby. They make it very hard to introduce concurrency issues between them, but put severe limitations on state sharing and cross-ractor communication. Ractors are only supported by CRuby, but that is generally not an issue, as other implementations, such as JRuby and TruffleRuby, support true parallelism with Threads. As of Ruby 4.0, Ractors are still considered experimental.
* **Fiber schedulers** allow you to run multiple Fibers concurrently on a single Thread, without having to explicitly pass control between them. This is a very efficient way to run concurrent code, especially for IO-bound workloads. As of Ruby 4.0, Fiber schedulers with IO support are still considered experimental.

All three of these need some form of **concurrency coordination** for shared state. These are usually the most complicated for Threads, as state is shared between them freely, and an interrupt can happen at any time. Fibers on the other hand have explicit control transfer (only on blocking operations or when giving up control), so their behavior is much more predictable. Ractors disallow sharing mutable state between them (or have built-in locking for the few cases where they allow it).

## The Problem

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
      <td>⚠️ CRuby only</td>
    </tr>
    <tr>
      <td>Queue</td>
      <td>⚠️ CRuby only</td>
      <td>❌ <b>not supported</b></td>
      <td>⚠️ CRuby only</td>
    </tr>
    <tr>
      <td rowspan="3"><a href="https://github.com/joshuay03/atomic-ruby">atomic-ruby</a></td>
      <td>AtomicQueue, AtomicThreadPool</td>
      <td>⚠️ CRuby only</td>
      <td>⚠️ CRuby only</td>
      <td>❌ <b>not supported</b></td>
    </tr>
    <tr>
      <td>Atom, AtomicCountDownLatch, AtomicBoolean</td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
      <td>⚠️ CRuby only<b>¹</b></td>
    </tr>
    <tr>
      <td>AtomicConditionVariable</td>
      <td>⚠️ CRuby only</td>
      <td>❌ <b>not supported</b></td>
      <td>❌ <b>not supported</b></td>
    </tr>
  </tbody>
</table>

Notes:
1. Incorrectly flags mutable objects as frozen.
2. Breaking Ractor isolation introduces concurrency issues not just in application code, but in Ruby itself, possibly leading to segmentation faults or undefined behavior. Note that `ractor_queue` has the ability to enforce shareability, but this feature is opt-in.

## The Solution

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

## Example

A map and a mutable string can be shared across Ractors. The transaction keeps their updates together. This example deliberately creates many Ractors. For application workloads, use [a pool](scheduling.md#ractor-pools) to reuse workers.

```ruby
require "farce"

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

## Read Next

[README](../README.md#features) · [Data Structures](data-structures.md) · [Concurrency](concurrency.md)
