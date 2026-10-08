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
# We'll just pick a random key one hundred times and increase the corresponding counter by one.
# Oh, and update the output string.
100.times.map do

  # And of course we need to do it all in parallel for maximum performance!
  # Let's ignore the fact that this would be much faster if we didn't.
  # Starting 100 ractors is the main performance issue here. But that wouldn't be an interesting example, right?
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

# Lets be sure that first ractor has completed its modification
ractor.join

# Hello from ✨ Farce ✨! The map has 3 entries with a total sum of 100.
puts output
```

**You don't see why you'd want this?**<br>
→ Start with the [Introduction](#introduction).

**Now you want to know what else Farce can do?**<br>
→ Check out the [Features](#features)!

**Returning user and you need the details?**<br> 
→ See the [API reference](https://rkh.github.io/farce/).

**Want to contribute?**<br>
→ Read the [contribution guide](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), and [security policy](SECURITY.md).


## Table of Contents

- [Farce: Fiber and Ractor Compatibility Enabler](#farce-fiber-and-ractor-compatibility-enabler)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
    - [The Problem](#the-problem)
    - [The Solution](#the-solution)
  - [Features](#features)
  - [Compatibility and Dependencies](#compatibility-and-dependencies)
    - [Ruby](#ruby)
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

# Works with tha async gem
Async do
  5.times do
    Async { counter.increment }
  end
end

wait_for.each(&:join)
counter.to_i # => 20
```

Farce also aims to be fast and efficient, aiming for anywhere between a minimal overhead to outperforming other options.

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

TODO

## Compatibility and Dependencies

Farce has no mandatory dependencies beyond Ruby itself.

### Ruby

Upon release of the latest version of Farce, it assumes to be compatible with:

* The [latest patch release](https://www.ruby-lang.org/en/downloads/releases/) for each [CRuby](https://www.ruby-lang.org/en/) version [still receiving bug fixes](https://www.ruby-lang.org/en/downloads/branches/).
* Ruby's [master branch](https://github.com/ruby/ruby/tree/master) at the time of release (ie the upcoming major version of CRuby).
* The latest stable release of [JRuby](https://www.jruby.org/) and [TruffleRuby](https://truffleruby.dev/) (both in native and GraalVM modes).

Moreover:

* Dropping support for a CRuby version is only done in major releases.
* If support for an older CRuby version is dropped, Farce will still backport security fixes for at least as long as that CRuby version is [still receiving security fixes](https://www.ruby-lang.org/en/downloads/branches/).

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
