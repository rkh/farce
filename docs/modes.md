<!--
# @title Transfer modes
-->

# Transfer modes

Farce adds transfer modes for handling non-shareable data between Ractors.
This improves over the default control via `Ractor::Port`'s `move:` option.

## Table of Contents

- [Transfer modes](#transfer-modes)
  - [Table of Contents](#table-of-contents)
  - [Introduction: What Ruby gives you](#introduction-what-ruby-gives-you)
      - [What `move: true` does on `Ractor::Port`](#what-move-true-does-on-ractorport)
  - [Farce's Modes](#farces-modes)
    - [`:copy`: keep working with the original](#copy-keep-working-with-the-original)
    - [`:move`: hand off a finished batch](#move-hand-off-a-finished-batch)
    - [`:local`: preserve object identity](#local-preserve-object-identity)
    - [`:make_shareable`: publish the original](#make_shareable-publish-the-original)
    - [`:shareable_copy`: publish without freezing your draft](#shareable_copy-publish-without-freezing-your-draft)
    - [`:dedup`: reuse equal values](#dedup-reuse-equal-values)
    - [`:raise`: require prepared data](#raise-require-prepared-data)
    - [Set a default, then override individual sends](#set-a-default-then-override-individual-sends)
    - [Let local sends keep their identity](#let-local-sends-keep-their-identity)
  - [Other classes that support modes](#other-classes-that-support-modes)
    - [Queue work for another Ractor](#queue-work-for-another-ractor)
    - [Add priorities or delayed delivery](#add-priorities-or-delayed-delivery)
    - [Exchange mutable messages with a partner](#exchange-mutable-messages-with-a-partner)
    - [Publish state through an atom or map](#publish-state-through-an-atom-or-map)
    - [Store a series of snapshots in a vector](#store-a-series-of-snapshots-in-a-vector)
    - [Pass task data as arguments](#pass-task-data-as-arguments)
  - [Under the hood](#under-the-hood)
    - [Envelopes separate transport from access](#envelopes-separate-transport-from-access)
    - [When copying and moving happen](#when-copying-and-moving-happen)
    - [Forward envelopes without opening them](#forward-envelopes-without-opening-them)
    - [Mode managers prepare values and open their own envelopes](#mode-managers-prepare-values-and-open-their-own-envelopes)
    - [Add modes to your own abstraction](#add-modes-to-your-own-abstraction)


## Introduction: What Ruby gives you

A shareable object can be used by several Ractors at once. Symbols, integers, and deeply frozen data are common examples. A mutable array or hash is normally non-shareable. Freezing just the outer container is not enough if it still contains mutable objects. Ruby provides [`Ractor.shareable?` and `Ractor.make_shareable`](https://docs.ruby-lang.org/en/4.0/Ractor.html#class-Ractor-label-Shareable+and+unshareable+objects) to check and prepare data.

```ruby
Ractor.shareable?(:ready)                   # => true
Ractor.shareable?([1, 2])                   # => false
Ractor.shareable?([String.new("draft")].freeze) # => false

settings = { formats: [String.new("json")] }
Ractor.make_shareable(settings)
Ractor.shareable?(settings)                 # => true
settings[:formats].frozen?                  # => true
```

Shareability does not always mean immutability. Farce provides shareable objects such as queues and atoms with coordinated operations. A shareable queue can still carry mutable application data. Its transfer mode determines how that data becomes available to the reader.

#### What `move: true` does on `Ractor::Port`

Ruby's [`Ractor::Port`](https://docs.ruby-lang.org/en/4.0/Ractor/Port.html#method-i-send) sends shareable objects by reference. It copies non-shareable objects by default. With `move: true`, the sender gives up access to the non-shareable parts of the message. Only the Ractor that created a port can receive from it.

```ruby
# Native Ruby 4.0 or later.
port = Ractor::Port.new
message = [1, 2]
port.send(message)
message << 3
port.receive # => [1, 2]

batch = [4, 5]
port.send(batch, move: true)
# Do not use batch after sending it. Its contents have been moved.
port.receive # => [4, 5]
port.close
```

Farce extends this choice with eight named modes.

## Farce's Modes

The following modes are accepted by `Farce::Port`. They apply to non-shareable values. Already-shareable values pass through unchanged, including when you select `:move` or `:raise`.

| Mode | What happens to non-shareable data | A typical use |
| --- | --- | --- |
| `:copy` (default) | Transfers a copy and leaves the original usable. This is the default. | Send a snapshot of a request. |
| `:move` | Transfers ownership and makes the original inaccessible. | Hand a completed batch to a consumer. |
| `:local` | Keeps the same object in its originating Ractor. | Pass work between local threads or fibers. |
| `:make_shareable` | Calls `Ractor.make_shareable` on the original. | Publish finished configuration. |
| `:shareable_copy` | Makes a shareable copy and leaves the original alone. | Publish a snapshot of an editable document. |
| `:dedup` | Deduplicates the value, then makes it shareable. May update and freeze the original. | Reuse repeated message contents. |
| `:proxy` | Creates a `Farce::Proxy` that executes calls in the original Ractor. | Share access to a mutable object. |
| `:raise` | Raises `Ractor::IsolationError`. | Enforce a shareable-data boundary. |

### `:copy`: keep working with the original

Copying is a good starting point for ordinary hashes, arrays, and strings. The receiver can change its copy without changing the sender's data. Shareable parts of the message can still be reused.

```ruby
port = Farce::Port.new
request = { ids: [10, 20] }
port.send(request)
request[:ids] << 30

received = port.receive
received[:ids] # => [10, 20]
received[:ids] << 40
request[:ids]  # => [10, 20, 30]
port.close
```

Copying is not a way to serialize every Ruby object. Some objects cannot be copied across Ractors. Choose a mode that fits the value, or send ordinary data from which the receiver can build what it needs.

### `:move`: hand off a finished batch

Moving is useful when a producer has finished building a message and will never use it again. It avoids copying the payload. Do not retain a plan to reuse the original or its moved nested objects after sending.

```ruby
results = Farce::Port.new(mode: :move)
producer = Farce::Ractor.new(results) do |outbox|
  rows = [[1, 100], [2, 250]]
  outbox.send(rows)
  # rows now belongs to the receiving side.
  nil
end

received = results.receive
received << [3, 75]
received.length # => 3
producer.join
results.close
```

Moving does not freeze the received data. The receiver can continue editing it. Attempting to use a moved source object raises a moved-object error on native Ractors.

### `:local`: preserve object identity

Use `:local` when the producer and consumer run in the same Ractor. This includes different threads or fibers in that Ractor. The receiver gets the original object, so changes made before receiving are visible.

```ruby
port = Farce::Port.new(mode: :local)
job = { steps: [] }

Thread.new { port.send(job) }.join
job[:steps] << :prepared

received = port.receive
received.equal?(job) # => true
received[:steps]     # => [:prepared]
port.close
```

A different Ractor cannot open a local payload. For example, sending non-shareable data with `:local` from a worker to a port owned by the main Ractor makes receiving fail with `Farce::Envelope::AlreadyClaimed`. Local mode also does not synchronize later edits to the payload. Coordinate concurrent mutation yourself.

### `:make_shareable`: publish the original

Use `:make_shareable` when a value is finished and every reader should see the same shareable object. For ordinary arrays and hashes, this recursively freezes their contents. All existing references to that data see the freezing too.

```ruby
port = Farce::Port.new(mode: :make_shareable)
settings = { retries: [1, 2, 5] }
port.send(settings)

published = port.receive
published.equal?(settings)           # => true
Farce::Ractor.shareable?(published)  # => true
settings[:retries].frozen?           # => true
port.close
```

Ruby raises an error if the value cannot be made shareable. This mode works well for configuration and completed lookup tables, but it cannot turn arbitrary resources into shared objects.

### `:shareable_copy`: publish without freezing your draft

Use `:shareable_copy` when readers need a stable snapshot but the sender will keep editing. Farce calls `Ractor.make_shareable(value, copy: true)`.

```ruby
port = Farce::Port.new(mode: :shareable_copy)
draft = { tags: [:ruby] }
port.send(draft)
draft[:tags] << :concurrency

published = port.receive
published[:tags]                     # => [:ruby]
Farce::Ractor.shareable?(published)  # => true
draft[:tags]                         # => [:ruby, :concurrency]
draft.frozen?                        # => false
port.close
```

### `:dedup`: reuse equal values

Use `:dedup` when messages contain repeated values. Farce calls `Farce.dedup(value)`, then makes the result Ractor-shareable. Equal strings, arrays, hashes, and Ruby Sets can reuse cached instances, including nested values.

```ruby
port = Farce::Port.new(mode: :dedup)
port.send([String.new("ready")])
first = port.receive
port.send([String.new("ready")])
second = port.receive

second.equal?(first)                 # => true
Farce::Ractor.shareable?(second)     # => true
port.close
```

Deduplication may update and freeze the original. The cache holds values weakly, so keep a reference to a result when its identity matters. Already-shareable inputs pass through unchanged. On JRuby and TruffleRuby, ordinary values are already shareable and skip deduplication. Values that cannot be made shareable raise an error.

### `:raise`: require prepared data

Use `:raise` when callers should prepare shareable messages explicitly. A bad value fails at the send operation, where the caller can fix it.

```ruby
port = Farce::Port.new(mode: :raise)
port.send(:ready)
port.receive # => :ready

begin
  port.send({ ids: [1, 2] })
rescue Farce::Ractor::IsolationError
  # Prepare the message before retrying.
end

message = Farce::Ractor.make_shareable({ ids: [1, 2] })
port.send(message)
port.receive.equal?(message) # => true
port.close
```

### Set a default, then override individual sends

A port's `mode:` sets its default. A `mode:` on `send` changes that message alone. `send` also accepts Ruby's `move:` option. An explicit mode takes precedence over `move:`. On a port whose default is `:move`, `move: false` selects `:copy`. On other ports, `move: false` keeps the default.

```ruby
port = Farce::Port.new(mode: :raise)
port.send([1, 2], mode: :copy)
port.receive # => [1, 2]
port.mode    # => :raise
port.close

handoff = Farce::Port.new(mode: :move)
batch = [3, 4]
handoff.send(batch, move: false)
handoff.receive # => [3, 4]
batch << 5      # The original is still usable.
handoff.close
```

### Let local sends keep their identity

`auto_local: true` makes a port use `:local` for non-shareable messages sent from its owning Ractor. Sends from other Ractors still use the selected mode. This is useful for an inbox receiving both local work and remote results.

```ruby
port = Farce::Port.new(mode: :copy, auto_local: true)
local_job = { ids: [1] }
port.send(local_job)
port.receive.equal?(local_job) # => true

# Force a snapshot even though the sender owns the port.
port.send(local_job, mode: :copy, auto_local: false)
port.receive.equal?(local_job) # => false
port.close
```

Automatic local transfer takes precedence even over an explicit `mode:` or `move:`. Disable it for a particular send when the selected transfer behavior matters. Its default is `false` on ports.

## Other classes that support modes

The same choices appear in several Farce APIs. Containers normally default to `:copy` and unwrap their managed values when you read them. Setting a container's mode does not make the values it returns shareable.

| Class | Where to select a mode | What it controls |
| --- | --- | --- |
| `Farce::Queue` | `new`, `push`, `try_push` | Queued values. |
| `Farce::PriorityQueue` | `new`, `push`, `try_push` | Values, independently of priority. |
| `Farce::TimerQueue` | `new`, `push`, `try_push` | Values, independently of their scheduled time. |
| `Farce::Exchanger` | `new`, `exchange` | The value offered to a partner. |
| `Farce::Atom` | `new`, `store`, `swap`, `update`, and other replacement operations | The stored value. |
| `Farce::Vector` | `new`, `push`, `store`, `update`, and other replacement operations | Element values. |
| `Farce::Set`, `Farce::SortedSet` | `new`, `add`, `add?` | Set elements. Membership uses an insertion-time snapshot. |
| `Farce::Map`, `Farce::WeakKeyMap` | `new`, `store`, `update`, and other replacement operations | Values only. Keys must already be shareable. |
| `Farce::TreeMap` | `new` | Values only. Keys follow the tree map's own rules. |
| `Farce::LRUMap` | `new` | Values only. Individual value hits and writes update eviction order. |
| `Farce::LFUMap` | `new` | Values only. Individual value hits and writes update eviction frequency. |
| `Farce::Scheduler` | `schedule` | Task arguments, with automatic local transfer enabled by default. |
| `Farce::ThreadScheduler` | `schedule`, `execute` | Accepts scheduler options but always keeps arguments local. |
| `Farce::Pool` | `schedule` | Task arguments. `:local` is rejected. |

### Queue work for another Ractor

Unlike a port, a queue does not restrict consumption to its creator. This makes a queue a natural place to hand work to a consumer. Here the worker gets ownership of a batch and sends back a shareable integer.

```ruby
jobs      = Farce::Queue.new(mode: :move)
results   = Farce::Port.new(mode: :raise)
worker    = Farce::Ractor.new(jobs, results) do |inbox, outbox|
  numbers = inbox.pop
  outbox.send(numbers.sum)
end

jobs.push([10, 20, 30])
results.receive # => 60
worker.join
results.close
```

### Add priorities or delayed delivery

Priority and timing do not change the meaning of a mode. You can select a default for the queue and override it for an individual item.

```ruby
urgent = Farce::PriorityQueue.new(mode: :shareable_copy)
urgent.push({ action: :refresh }, priority: 0)
urgent.pop # => { action: :refresh }

retries = Farce::TimerQueue.new(mode: :copy)
retries.push({ attempt: 2 }, at: Farce::Clock.now, mode: :make_shareable)
Farce::Ractor.shareable?(retries.pop) # => true
```

Wrapping happens before waiting for queue space or an exchange partner. A failed `try_push` or a timeout can therefore leave a value moved or frozen. Use copying when you need to retain the original for a retry. Also, reading a moved payload can claim it: `TimerQueue#peek` opens the payload even though it leaves the item queued.

### Exchange mutable messages with a partner

An exchanger pairs two callers. Each caller receives the other's offered value. Copy mode lets both callers retain their originals.

```ruby
exchange   = Farce::Exchanger.new(mode: :copy)
worker     = Farce::Ractor.new(exchange) do |meeting|
  received = meeting.exchange({ status: :ready })
  received[:command] # => :start
end

reply = exchange.exchange({ command: :start })
reply # => { status: :ready }
worker.join
```

### Publish state through an atom or map

Shareable snapshots work well when multiple Ractors read the same state. Replace a snapshot through the container's update operation instead of mutating a returned hash or array. The mode also applies to the replacement returned by the block.

```ruby
state = Farce::Atom.new({ completed: 0 }, mode: :make_shareable)
state.update { |current| { completed: current[:completed] + 1 } }
state.value # => { completed: 1 }

cache = Farce::Map.new(mode: :shareable_copy)
draft = { roles: [:reader] }
cache[:account] = draft
draft[:roles] << :editor
cache[:account] # => { roles: [:reader] }

cache.update(:account) { |current| { roles: current[:roles] + [:admin] } }
cache[:account] # => { roles: [:reader, :admin] }
```

`Farce::WeakKeyMap` uses the same value modes, but keeps its keys weakly. `Farce::TreeMap` keeps entries sorted by key and selects the value mode at construction. Modes do not copy or wrap map keys. Tree maps also make mutable string keys immutable.

### Store a series of snapshots in a vector

A vector can apply a mode to its initial elements and to later writes. Use `push` or `store` when an individual write needs a different mode.

```ruby
history = Farce::Vector.new([], mode: :shareable_copy)
draft = { version: 1 }
history.push(draft)
draft[:version] = 2
history.push(draft)

history[0] # => { version: 1 }
history[1] # => { version: 2 }
Farce::Ractor.shareable?(history[0]) # => true
```

For containers that retain values, `:copy` gives each Ractor its own copy of a stored envelope's contents. Repeated reads in the same Ractor reuse that copy. Mutating it does not publish an update to other Ractors. Prefer explicit replacement operations for shared state. Similarly, `:move` is usually better suited to a handoff than to a value many Ractors need to read.

### Pass task data as arguments

`Scheduler#schedule` and `Pool#schedule` accept `mode:` for task arguments. Pass mutable data as arguments instead of capturing it from the surrounding scope. A non-local task's block must be convertible to a shareable proc.

```ruby
pool = Farce::Pool.new(max_size: 2)
results = Farce::Port.new(mode: :raise)
batch = [2, 4, 6]

pool.schedule(batch, results, mode: :copy) do |numbers, outbox|
  outbox.send(numbers.sum)
end

results.receive # => 12
pool.close
results.close
```

A scheduler defaults to `auto_local: true`, preserving the block and its arguments when scheduling from its owning Ractor. Set `auto_local: false` to enforce the requested mode there. A pool may choose another Ractor for any task, so it rejects `:local` and does not apply automatic local transfer.

## Under the hood

### Envelopes separate transport from access

A `Farce::Envelope` is a shareable wrapper around a value. Passing the envelope around does not require opening it. Calling `value` opens it and retrieves the payload according to the envelope's ownership rules.

```ruby
source = { ids: [1, 2] }
envelope = Farce::Envelope.new(source, mode: :copy)
Farce::Ractor.shareable?(envelope) # => true
source[:ids] << 3

envelope.value[:ids]                  # => [1, 2]
envelope.value.equal?(envelope.value) # => true
```

`Envelope.new` defaults to `:copy` and accepts `:copy`, `:move`, or `:local`. These are envelope types, not the full set of manager modes. A shareable payload produces an `Envelope::Share`. The other manager modes either prepare shareable data directly or raise an error.

### When copying and moving happen

A copy envelope copies its non-shareable payload into internal storage when created. Each Ractor that opens it gets another copy, cached for that Ractor. A move envelope moves the payload into storage immediately, then moves it out when the winning Ractor first opens it. Forwarding either envelope does not add a payload copy or move at every hop.

| Envelope | Who can open it? | What repeated reads return |
| --- | --- | --- |
| `Envelope::Copy` | Any Ractor. | That Ractor's cached copy. |
| `Envelope::Move` | The first Ractor to claim it. | The owning Ractor's received object. |
| `Envelope::Local` | Its creating Ractor. | The original object. |
| `Envelope::Share` | Any Ractor. | The shared payload. |

A claim belongs to a Ractor, not a thread or fiber, and cannot be revoked. `claim` returns the envelope on success or `nil` if another Ractor owns it. `claim!` and `value` raise `Farce::Envelope::AlreadyClaimed` on failure. Use `claimed?` to ask whether it has an owner and `owned?` to ask whether the current Ractor can open it. Copy and share envelopes report both as true because every Ractor can open them.

### Forward envelopes without opening them

An explicitly created envelope stays an envelope when passed through a Farce port or queue. This lets a dispatcher route a job without taking ownership of the job's mutable contents. In this example, only the consumer opens the move envelope.

```ruby
incoming  = Farce::Queue.new(mode: :raise)
ready     = Farce::Queue.new(mode: :raise)
results   = Farce::Port.new(mode: :raise)

router    = Farce::Ractor.new(incoming, ready) do |inbox, outbox|
  package = inbox.pop
  # Route the shareable wrapper. Do not call package.value here.
  outbox.push(package)
end

consumer  = Farce::Ractor.new(ready, results) do |inbox, outbox|
  package = inbox.pop
  numbers = package.value
  outbox.send(numbers.sum)
end

payload = [10, 20, 30]
package = Farce::Envelope.new(payload, mode: :move)

# payload is already moved, before the first queue operation.
incoming.push(package)

results.receive # => 60
router.join
consumer.join
results.close
```

Both queues accept the envelope in `:raise` mode because the wrapper is shareable. Neither queue opens it automatically. For routing metadata, put the envelope in a shareable message such as `[:billing, package].freeze`. The router can read the destination without accessing the payload.

### Mode managers prepare values and open their own envelopes

`Farce::ModeManager` provides two core operations: `wrap` prepares a value for shared storage, and `unwrap` retrieves values from envelopes that this manager created. It passes already-shareable values through unchanged. For non-shareable values, `:copy`, `:move`, and `:local` create managed envelopes. The remaining modes call `Ractor.make_shareable`, make a shareable copy, deduplicate and make the result shareable, or raise.

```ruby
manager = Farce::ModeManager.new(mode: :copy)
source = { ids: [1] }
stored = manager.wrap(source)
source[:ids] << 2
manager.unwrap(stored) # => { ids: [1] }

# A different manager leaves this wrapper intact.
other = Farce::ModeManager.new
other.unwrap(stored).equal?(stored) # => true

# So does the original manager for a user-created envelope.
explicit = Farce::Envelope.new([3, 4], mode: :move)
manager.unwrap(manager.wrap(explicit)).equal?(explicit) # => true
explicit.claimed? # => false
```

Containers automatically open the envelopes they created to implement a mode. They preserve envelopes supplied as application data. Ports use the underlying port's native copy and move paths for those two modes, and a mode manager for the additional behaviors.

### Add modes to your own abstraction

Keep one manager per instance when building an abstraction around shareable storage. Use the same manager on both the write and read paths. Here a strict Farce queue stands in for storage that accepts only shareable objects.

```ruby
class WorkInbox
  include Farce::Shareable

  def initialize(mode: :copy)
    @manager = Farce::ModeManager.new(mode: mode)
    @storage = Farce::Queue.new(mode: :raise)
    super()
  end

  def push(value, mode: nil)
    @storage.push(@manager.wrap(value, mode: mode))
    self
  end

  def pop
    @manager.unwrap(@storage.pop)
  end
end

inbox = WorkInbox.new(mode: :shareable_copy)
draft = { ids: [1, 2] }
inbox.push(draft)
draft[:ids] << 3
inbox.pop # => { ids: [1, 2] }
```

In application code, `Farce::Queue` already does this work. A separate manager is useful when adapting another storage primitive or building a larger abstraction. It provides the same transfer choices while preserving user-created envelopes for later processing.
