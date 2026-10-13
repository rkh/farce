# Farce: Fiber and Ractor Compatibility Enabler

Farce provides mutable data structures and coordination tools for Ruby code that uses **threads, Ractors, and Fiber schedulers**. Use it to share state between workers, connect background computation to an event loop, or make a gem compatible with the caller's concurrency model.

**Here's a taste:** four workers updating the same map, without losing increments or managing a lock.

```ruby
require "farce"

counts  = Farce::Map.new
workers = 4.times.map do
  Farce.in_parallel(counts) do |counts|
    100.times do
      counts.upsert(:completed, 1) { |count| count + 1 }
    end
  end
end
workers.each(&:join)

counts[:completed] # => 400
```

[Introduction](#introduction) · [Features](#features) · [Installation](#installation) · [Compatibility](#compatibility-and-dependencies) · [API reference](https://rkh.github.io/farce/)

## Introduction

Threads share memory, Ractors enable parallel Ruby execution on CRuby with restricted sharing, and Fiber schedulers handle concurrent IO efficiently. A primitive that works with one may fail with another.

Farce's shared containers preserve Ractor isolation. Their blocking operations suspend non-blocking fibers without stopping the scheduler. You can use them alongside existing gems, without adopting Farce's own schedulers.

→ [Why Farce exists, comparisons, and a larger example](docs/introduction.md).

## Features

### Data Structures

Use familiar Ruby APIs with coordinated access to shared state:

- **Maps, vectors, and sets** for collections, with sorted and weak-reference variants.
- **Atoms, counters, flags, and molecules** for individual values and structured records.
- **FIFO, priority, and timer queues** for passing work, applying back pressure, or delaying delivery.

For example, use a Vector as a shared list:

```ruby
list = Farce::Vector.new

100.times do
  Farce.in_parallel(list) { it << Some.expensive_computation }
end
```

Or use a bounded map as a shared cache:

```ruby
cache = Farce::LRUMap.new(max_size: 2)
cache[:a] = 1
cache[:b] = 2
cache[:c] = 3
cache.key?(:a) # => false, the least recently used entry was evicted
```

→ [Collection APIs and examples](docs/data-structures.md).

### Shims, Polyfills, and Extensions

- **`Farce::Ractor`** uses native Ractors on CRuby and threads on JRuby and TruffleRuby.
- **`Farce::Port`** adds transfer modes, receive timeouts, and Fiber scheduler support.
- **`Farce::WeakRef` and `Farce::Resolv`** work outside the main Ractor.

Send a result back from a worker:

```ruby
results = Farce::Port.new
worker  = Farce::Ractor.new(results) { |port| port.send(6 * 7) }
results.receive # => 42
```

→ [Portable Ractor APIs and extensions](docs/shims.md).

### Sharing Unshareable Data

Transfer modes control non-shareable values on native Ractors. For example, `:copy` sends a snapshot while leaving the original usable:

```ruby
queue = Farce::Queue.new(mode: :copy)
job   = { ids: [1, 2] }
queue.push(job)
job[:ids] << 3 # added after copying

Ractor.new(queue) do |queue|
  queue.pop # => { ids: [1, 2] }
end
```

JRuby and TruffleRuby share ordinary values directly (`Farce::Ractor.shareable?` reflects this).

Other tools cover different ownership needs:

- **Envelopes** carry values through several Ractors without repeated transfers.
- **Mutables** synchronize edits to wrapped objects.
- **Proxies** run calls in the object's original Ractor.
- **Leases and lease pools** give callers exclusive access to reusable resources, such as connections.

→ [Transfer modes, wrappers, and resource checkout](docs/sharing.md).

### Variants and Scopes

Choose where state lives and what it can contain:

| Variant           | Use it when…                                                                          |
|-------------------|---------------------------------------------------------------------------------------|
| `Farce`           | Workers across Ractors need shared state, including values handled by transfer modes. |
| `Farce::Strict`   | All stored values must already be shareable.                                          |
| `Farce::Unshared` | Threads in one Ractor need to store arbitrary Ruby objects directly.                  |
| `Farce::Local`    | Each Ractor, thread, or fiber needs its own contents behind one handle.               |

For example, keep request context separate for each fiber:

```ruby
context = Farce::Local::Map.new(scope: :fiber)
context[:request_id] = :parent
Fiber.new { context[:request_id] = :child }.resume
context[:request_id] # => :parent
```

Available variants depend on the class. → [All variants and scopes](docs/variants-and-scopes.md).

### Concurrency

- **Atomic operations**, such as `upsert` above, combine reads and writes.
- **Wait methods and signals** wait for state changes without managing condition variables.
- **Transactions** publish coupled changes together. Locks are available too.

Use a flag to wait for an event:

```ruby
flag = Farce::Flag.new

Thread.new do
  lots_of_work_here
  flag.set
end

flag.wait_until_set
```

Transfer funds without exposing a partially updated balance:

```ruby
accounts = Farce::Map.new({ checking: 100, savings: 0 })
Farce.transaction(accounts) do |tx, balances|
  tx.abort! if balances[:checking] < 20
  balances[:checking] -= 20
  balances[:savings] += 20
end
accounts.to_h # => { checking: 80, savings: 20 }
```

Transaction blocks may rerun after a conflict. Keep external side effects outside them.

→ [Atomic updates, waiting, locks, and transactions](docs/concurrency.md).

### Scheduling Code

- **`Farce.schedule`** runs background work, using an available local scheduler when possible.
- **`Farce.on_main`** dispatches calls to the main Ractor.
- **`Farce.in_parallel`** schedules parallel work, reusing a Ractor pool on CRuby.

Use a task when you need the result:

```ruby
task = Farce::Task.in_parallel(21) { |number| number * 2 }
task.value # => 42, waits for completion
```

You can also create your own schedulers and pools, or use third-party Fiber schedulers.

→ [Tasks, execution choices, and scheduler lifecycle](docs/scheduling.md).

### Integrations

Use Farce collections with existing libraries:

- **Active Support** adds helpers such as indifferent key access.
- **Dry Types** validates and coerces Farce collections.
- **JSON, YAML, MessagePack, BSON, and CBOR** serialize them.
- **TVar adapters** bring existing transactional values into Farce transactions.

```ruby
require "json"
require "farce"

map = Farce::Map.new({ ids: Farce::Vector[1, 2] })
map.to_json # => '{"ids":[1,2]}'
```

Integrations load when both libraries have been required, in either order. Farce does not load the other library for you.

→ [Integration APIs and disabling automatic loading](docs/integrations.md).

### Utilities and Custom Classes

Adapt existing data without rebuilding it by hand:

```ruby
config = Farce.enfarce({ retries: [1, 2, 3] })
config.class          # => Farce::Map
config[:retries].class # => Farce::Vector
```

Other helpers freeze object graphs, deduplicate values, and measure monotonic time. Lazy values and exchangers coordinate initialization and handoffs. Shareability mixins define how custom classes can be frozen, shared, copied, or moved.

→ [Conversion helpers and extension points](docs/utilities.md).

## Installation

Add to your application's `Gemfile`, then run `bundle install`:

```ruby
gem "farce"
```

For a library, add `spec.add_dependency "farce"` to its gemspec. Load the public entry point with `require "farce"`. Classes load lazily.

→ [Global installation and local development setup](docs/installation.md).

## Compatibility and Dependencies

Farce has **no mandatory dependencies beyond Ruby**. It supports maintained CRuby versions, the upcoming CRuby release, and current stable JRuby and TruffleRuby releases.

→ [Support policy, optional gem versions, and related projects](docs/compatibility.md) · [Benchmarks](docs/benchmarks.md).

## Known Issues and Limitations

Ruby's `freeze` and `frozen?` reflect Farce objects' mutability. Direct C-level frozen checks can report a different state for some objects.

→ [Frozen-state behavior for extension authors](docs/compatibility.md#known-issues-and-limitations).

## Housekeeping

Want to contribute? Read the [contribution guide](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), and [security policy](SECURITY.md).

Farce follows [Semantic Versioning](https://semver.org/) and [the RubyGems versioning policy](https://guides.rubygems.org/patterns/#versioning). Farce's original code is released under the [MIT License](MIT-LICENSE). Native builds also contain Kazlib 1.20-derived `dict.c` and `dict.h`; their original permissive license and copyright notice are retained in those files. The native gem therefore declares `MIT` and `LicenseRef-Kazlib-1.20`, while the pure-Java gem declares only `MIT` because it does not ship Kazlib.

Built with love in Berlin, by Konstantin Haase.
