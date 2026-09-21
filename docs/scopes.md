<!--
# @title Local scopes
-->

# Local scopes

Farce's local containers let you share one object while keeping separate contents for different Ractors, threads, or fibers. The `scope:` option selects which callers use the same contents.

## Table of Contents

- [Local scopes](#local-scopes)
  - [Table of Contents](#table-of-contents)
  - [Introduction: What Ruby gives you](#introduction-what-ruby-gives-you)
  - [One handle, separate contents](#one-handle-separate-contents)
  - [Choosing a scope](#choosing-a-scope)
    - [`:ractor`: share within a Ractor](#ractor-share-within-a-ractor)
    - [`:thread_group`: share within a group of threads](#thread_group-share-within-a-group-of-threads)
    - [`:thread`: keep one set of contents per thread](#thread-keep-one-set-of-contents-per-thread)
    - [`:fiber`: give every fiber its own contents](#fiber-give-every-fiber-its-own-contents)
    - [`:fiber_storage`: let child fibers share a context](#fiber_storage-let-child-fibers-share-a-context)
      - [Non-blocking fibers and schedulers](#non-blocking-fibers-and-schedulers)
  - [Classes that support scopes](#classes-that-support-scopes)
    - [Count within each scope](#count-within-each-scope)
    - [Keep a cache in each Ractor](#keep-a-cache-in-each-ractor)
    - [Create mutable values with a factory](#create-mutable-values-with-a-factory)
    - [Delegate through a lazy reference](#delegate-through-a-lazy-reference)
    - [Keep queues and their lifecycle local](#keep-queues-and-their-lifecycle-local)
    - [Build ordered collections in each scope](#build-ordered-collections-in-each-scope)
    - [Borrow resources from a local lease](#borrow-resources-from-a-local-lease)
    - [Group resources or limit their number](#group-resources-or-limit-their-number)
  - [Using scopes in an application](#using-scopes-in-an-application)
    - [Restore context when reusing a fiber](#restore-context-when-reusing-a-fiber)
    - [Pass local handles to scheduled tasks](#pass-local-handles-to-scheduled-tasks)
    - [Coordinate changes within a shared scope](#coordinate-changes-within-a-shared-scope)
  - [Under the hood](#under-the-hood)
    - [Resolve the current backing object on every operation](#resolve-the-current-backing-object-on-every-operation)
    - [Local handles can be garbage collected](#local-handles-can-be-garbage-collected)
    - [Initial configuration is reused in new scopes](#initial-configuration-is-reused-in-new-scopes)
    - [Separate containers can contain the same objects](#separate-containers-can-contain-the-same-objects)
    - [Fiber storage inherits a reference to Farce storage](#fiber-storage-inherits-a-reference-to-farce-storage)
    - [Scopes and transfer modes solve different problems](#scopes-and-transfer-modes-solve-different-problems)

## Introduction: What Ruby gives you

Ruby has several places to store execution-local state. `Thread.current.thread_variable_set` stores a value for an entire thread. Despite its name, `Thread.current[:key]` stores a value for the current fiber.

```ruby
Thread.current.thread_variable_set(:scopes_example, :thread_value)
Thread.current[:scopes_example] = :fiber_value

values = Fiber.new do
  [Thread.current.thread_variable_get(:scopes_example),
   Thread.current[:scopes_example]]
end.resume

values # => [:thread_value, nil]
Thread.current.thread_variable_set(:scopes_example, nil)
Thread.current[:scopes_example] = nil
```

`Fiber[:key]` is another API. It supports storage inheritance when new fibers are created. Farce gives these choices a common interface through `scope:`, and adds Ractor and thread-group scopes. You can change the scope without rewriting each operation on your map, queue, or lazy value.

## One handle, separate contents

A `Farce::Local` object is a shareable handle. Each operation finds the contents associated with the current scope. The handle is shareable while its contents remain mutable. Freezing a Local data container prevents explicit changes in every scope, including scopes first accessed later. Each scope keeps its own values. Local services such as queues and leases, and `Local::Lazy`, reject freezing with `TypeError`. Unlike a named slot in Ruby's built-in local storage, the local instance can also be garbage collected while the surrounding Ractor, thread, or fiber is still alive.

```ruby
require "farce"

context = Farce::Local::Map.new(scope: :fiber)
context[:request_id] = :parent

child_value = Fiber.new do
  context[:request_id] = :child
  context[:request_id]
end.resume

child_value                          # => :child
context[:request_id]                 # => :parent
context.scope                        # => :fiber
Farce::Ractor.shareable?(context)    # => true
context.frozen?                      # => false
```

Call `freeze` only after coordinating with writers. It does not wait for operations already in progress. Freezing is shallow, so objects stored in a container remain independently mutable. Weak containers still allow garbage collection of their contents.

Load `farce` before running the remaining examples. Each code block is independent. Examples use `Farce::Ractor` so they can also use Farce's compatibility layer where native Ractors are unavailable.

## Choosing a scope

Choose a scope based on who should see the same state. All these scopes are selected at construction. The default is `:ractor`. There is no `:global` scope for local containers (use the non-local variants of the storage classes instead).

| Scope | Who uses the same contents? | A typical use |
| --- | --- | --- |
| `:ractor` | Threads and fibers in the same Farce Ractor. | A cache for each worker Ractor. |
| `:thread_group` | Threads in the same `ThreadGroup` within a Ractor, including their fibers. | State for a group of related worker threads. |
| `:thread` | All fibers in one thread. | A reusable object for each worker thread. |
| `:fiber` | Only the current fiber. | Independent request state. |
| `:fiber_storage` | Execution contexts that inherit the same Farce storage entry through Ruby fiber storage. | Context shared with child fibers. |

### `:ractor`: share within a Ractor

Use the default scope when each Ractor should have its own state. Threads inside one Ractor still use the same contents. Sending the handle to another Ractor gives that Ractor access to its own contents.

```ruby
state = Farce::Local::Map.new
state[:worker] = :main
Thread.new { state[:completed] = 3 }.join
state[:completed] # => 3

results = Farce::Port.new
worker = Farce::Ractor.new(state, results) do |local, outbox|
  before = local.empty?
  local[:worker] = :background
  outbox.send([before, local[:worker]])
end

results.receive # => [true, :background]
state[:worker]  # => :main
worker.join
results.close
```

The background Ractor starts with an empty map because this map had no initial entries. It does not inherit writes made through the main Ractor's handle. On platforms using Farce's thread-based Ractor shim, `:ractor` still selects storage by the current Farce Ractor.

### `:thread_group`: share within a group of threads

Use `:thread_group` when a group of threads should share state separately from other groups. Ruby's [`ThreadGroup`](https://docs.ruby-lang.org/en/4.0/ThreadGroup.html) lets you assign threads to groups. New threads inherit their creator's group.

```ruby
state = Farce::Local::Map.new(scope: :thread_group)
state[:service] = :web
background = ThreadGroup.new

result = Thread.new do
  inherited = state[:service]
  background.add(Thread.current)
  starts_empty = state.empty?
  state[:service] = :indexer

  child_value = Thread.new { state[:service] }.value
  [inherited, starts_empty, child_value]
end.value

result          # => [:web, true, :indexer]
state[:service] # => :web
```

Moving a thread to another group changes which contents subsequent operations select. Put workers into their intended group before they start using group-local resources. Membership in a group does not make independent edits to a returned mutable object atomic.

### `:thread`: keep one set of contents per thread

Use `:thread` when fibers on the same thread should reuse state. A new thread starts with its own contents, even if it belongs to the same thread group.

```ruby
state = Farce::Local::Map.new(scope: :thread)
state[:worker] = :main

Fiber.new { state[:worker] }.resume # => :main

other = Thread.new do
  before = state.empty?
  state[:worker] = :background
  [before, Fiber.new { state[:worker] }.resume]
end.value

other          # => [true, :background]
state[:worker] # => :main
```

Thread-local state lasts across multiple jobs handled by the same thread. This suits caches and reusable helpers. For request-specific state, use a narrower scope or explicitly restore the previous value when a request finishes.

### `:fiber`: give every fiber its own contents

Use `:fiber` when each fiber should start independently. Child fibers do not inherit the parent's local contents. Suspending and resuming a fiber preserves that fiber's contents.

```ruby
request = Farce::Local::Atom.new(nil, scope: :fiber)
request.value = :outer

work = Fiber.new do
  before = request.value
  request.value = :upload
  Fiber.yield(before)
  request.value
end

work.resume   # => nil
request.value # => :outer
work.resume   # => :upload
request.value # => :outer
```

This is useful when an application runs one request per fiber. It also means that a helper which starts a new fiber must receive any needed request data explicitly.

### `:fiber_storage`: let child fibers share a context

Use `:fiber_storage` when related fibers should see the same local context. Ruby's [`Fiber.new`](https://docs.ruby-lang.org/en/4.0/Fiber.html#method-c-new) inherits a copy of the creator's fiber-storage hash by default. That copy can hold a reference to the same Farce storage object. A child can therefore update the same local map.

```ruby
context = Farce::Local::Map.new(scope: :fiber_storage)
context[:request_id] = :upload

child_result = Fiber.new do
  context[:stage] = :validated
  context[:request_id]
end.resume

child_result    # => :upload
context[:stage] # => :validated

# Start an independent context explicitly.
isolated = Fiber.new(storage: {}) do
  before = context.empty?
  context[:request_id] = :download
  [before, context[:request_id]]
end.resume

isolated             # => [true, :download]
context[:request_id] # => :upload
```

Set up the context before creating children that should inherit it. Inheritance happens at fiber creation, not when the child is resumed. Use `storage: {}` at a new request boundary when it should start without inherited fiber storage.

#### Non-blocking fibers and schedulers

`blocking: false` alone does not turn off Ruby's default storage inheritance. A scheduler controls where and how task fibers are created. Do not assume a scheduled task inherits the submitting fiber's context, especially when it runs in another thread or Ractor.

```ruby
context = Farce::Local::Map.new(scope: :fiber_storage)
context[:request_id] = :upload

Fiber.new(blocking: false) { context[:request_id] }.resume # => :upload
Fiber.new(blocking: false, storage: {}) { context.empty? }.resume # => true
```

Pass the needed data as task arguments when crossing an execution boundary. Use `:fiber` when each task fiber should get its own state regardless of inherited storage.

## Classes that support scopes

These classes accept the same five scopes. The scope determines which backing container or resource an operation uses. Each class retains its own behavior, such as queue ordering or weak references.

| Class | What each scope gets |
| --- | --- |
| `Farce::Local::Flag` | An atomic boolean with its own current value. |
| `Farce::Local::Counter` | An atomic integer counter with its own current value. |
| `Farce::Local::Atom` | An atomic reference with its own current value. |
| `Farce::Local::WeakAtom` | A reference that does not keep its value alive. |
| `Farce::Local::Map` | A mutable map. |
| `Farce::Local::TreeMap` | A map sorted by key. |
| `Farce::Local::LRUMap` | A bounded map with independent recency and capacity in each scope. |
| `Farce::Local::LFUMap` | A bounded map with independent frequency history and capacity in each scope. |
| `Farce::Local::WeakMap` | A map with weak keys and weak values. |
| `Farce::Local::WeakKeyMap` | A map with weak keys. |
| `Farce::Local::WeakValueMap` | A map with weak values. |
| `Farce::Local::Vector` | An indexed collection. |
| `Farce::Local::Queue` | A FIFO queue with independent capacity and lifecycle. |
| `Farce::Local::PriorityQueue` | A queue ordered by priority. |
| `Farce::Local::TimerQueue` | A queue whose values become available at scheduled times. |
| `Farce::Local::Lazy` | A value computed on first access in that scope. |
| `Farce::Local::LazyRef` | A reference that delegates to a scoped lazy value. |
| `Farce::Local::Lease` | An independently initialized resource to borrow. |
| `Farce::Local::LeaseMap` | An independently initialized set of named resources. |
| `Farce::Local::LeasePool` | A pool with its own resources and capacity. |

### Count within each scope

`Local::Counter` provides the numeric interface and atomic operations of `Farce::Counter`. Each scope starts at the configured initial integer. Reads and `reset` affect only the current scope. Values are not summed across scopes.

```ruby
completed = Farce::Local::Counter.new(10, scope: :thread)
completed.increment(3)

child = Thread.new do
  before = completed.value
  completed.increment
  completed.reset
  [before, completed.value]
end.value

child           # => [10, 10]
completed.value # => 13
completed + 2   # => 15
```

Updates remain atomic when multiple threads share a Ractor or thread-group scope. Conditional operations such as `increment_if_below` apply their bounds to that scope's counter.

### Keep a cache in each Ractor

A local map can hold mutable keys and values without preparing them for transfer. `store_if_absent` is useful for computing an entry once in the current map. Other Ractors maintain their own caches through the same handle.

```ruby
cache  = Farce::Local::Map.new
key    = String.new("ruby concurrency")

tokens = cache.store_if_absent(key) { key.split }
again  = cache.store_if_absent(key) { raise "already cached" }

again.equal?(tokens)              # => true
Farce::Ractor.shareable?(cache)   # => true
Farce::Ractor.shareable?(tokens)  # => false
```

Choose a weak map variant when entries should disappear as keys or values become unreachable. Scope selection does not change weak-reference behavior. Keep a strong reference elsewhere for as long as you need a weakly held object.

### Create mutable values with a factory

Use `Local::Lazy` to build a fresh object for each scope that needs it. Its factory runs on the first `value` call in that scope. Later calls return the cached result, including `nil` or `false` results.

```ruby
buffers = Farce::Local::Lazy.new(String, scope: :thread)
buffers.value << "main output"

child_output = Thread.new do
  buffer = buffers.value
  buffer << "worker output"
  buffer.dup
end.value

child_output  # => "worker output"
buffers.value # => "main output"
```

You can supply a class, a shareable callable, or a block that can be made Ractor-shareable. The factory may create mutable objects, but it cannot capture arbitrary mutable state from another Ractor. A block can capture shareable configuration or use the explicit `self:` option.

```ruby
settings = Farce::Ractor.make_shareable({ limit: 100 })
state = Farce::Local::Lazy.new(scope: :fiber, self: settings) do
  { limit: self[:limit], pending: [] }
end

state.value[:pending] << :parent
child = Fiber.new { state.value }.resume

child                       # => { limit: 100, pending: [] }
state.value[:pending]       # => [:parent]
```

### Delegate through a lazy reference

`Local::LazyRef` lets calling code use the result's interface directly. It selects the current scope's lazy value before forwarding the operation. This is handy for a library-level cache whose callers should not need to call `value` themselves.

```ruby
cache = Farce::Local::LazyRef.new(Hash, scope: :fiber)
cache[:page] = :parent

child = Fiber.new { cache[:page] = :child }.resume
child          # => :child
cache[:page]   # => :parent
```

### Keep queues and their lifecycle local

Use `Local::Queue` when producers and consumers should communicate inside the selected scope. With the default `:ractor` scope, different threads in the same Ractor can exchange the original mutable object.

```ruby
queue    = Farce::Local::Queue.new
job      = { ids: [1, 2] }
consumer = Thread.new { queue.pop }

queue.push(job)

consumer.value.equal?(job) # => true
queue.close
```

Capacity, queued values, and closing belong to the backing queue in that scope. A different scope has a different queue. A thread-local queue therefore cannot deliver work from one thread to another.

```ruby
queue = Farce::Local::Queue.new(scope: :thread, capacity: 1)
queue.push(:main_job)
queue.seal

other_state = Thread.new do
  [queue.empty?, queue.closed?, queue.capacity]
end.value

other_state   # => [true, false, 1]
queue.pop     # => :main_job
queue.closed? # => true
```

### Build ordered collections in each scope

Use local vectors and tree maps for per-scope collections. Local priority and timer queues apply their ordering within each scope too. Here each fiber gets an independent list of processing stages.

```ruby
stages = Farce::Local::Vector.new([:received], scope: :fiber)
stages.push(:validated)

child_stages = Fiber.new do
  stages.push(:decoded)
  [stages[0], stages[1]]
end.resume

child_stages           # => [:received, :decoded]
[stages[0], stages[1]] # => [:received, :validated]
```

### Borrow resources from a local lease

Use `Local::Lease` when callers in the same scope must take turns using a resource. Its initializer creates a resource on first use in each scope. The block form of `checkout` returns the resource to the lease when the block finishes, including when it raises.

```ruby
scratch = Farce::Local::Lease.new(scope: :thread) { String.new }

first = scratch.checkout do |buffer|
  buffer.replace("report: ")
  buffer << "ready"
  buffer.dup
end

second = scratch.checkout { |buffer| buffer.dup }
other = Thread.new { scratch.checkout { |buffer| buffer.empty? } }.value

first  # => "report: ready"
second # => "report: ready"
other  # => true
```

A lease reuses its resource within the scope. Clear or reset reusable buffers as part of your work when previous contents should not carry over. Keep checkout and use together in the block instead of letting borrowed resources escape into another scope.

### Group resources or limit their number

`Local::LeaseMap` builds a mapping of named resources per scope. `Local::LeasePool` creates resources as needed up to its limit. That limit applies separately in each scope, so `max_size: 2` with thread scope permits two resources per thread.

```ruby
resources = Farce::Local::LeaseMap.new(scope: :fiber) do
  { input: String.new, output: String.new }
end
resources.checkout(:output) { |buffer| buffer << "parent" }

Fiber.new { resources.checkout(:output) { |buffer| buffer.empty? } }.resume # => true

pool = Farce::Local::LeasePool.new(scope: :thread, max_size: 2) { [] }
pool.checkout { |items| items << :used }
Thread.new { pool.checkout { |items| items.empty? } }.value # => true
```

## Using scopes in an application

### Restore context when reusing a fiber

A scope is tied to an execution context, not to the lifetime of a Ruby method call. A thread or fiber that handles several requests keeps its local state between them. Use `ensure` to restore temporary context when nesting operations or reusing a worker.

```ruby
class RequestContext
  def initialize
    @current = Farce::Local::Atom.new(nil, scope: :fiber)
  end

  def current = @current.value

  def with(request_id)
    previous = @current.swap(request_id)
    begin
      yield
    ensure
      @current.value = previous
    end
  end
end

context = RequestContext.new

context.with(:outer) do
  context.with(:inner) { context.current } # => :inner
  context.current                         # => :outer
end

context.current # => nil
```

The wrapper above is an ordinary Ruby object used within one Ractor. Its local atom supplies fiber selection. A local field alone does not make an enclosing application object Ractor-shareable.

### Pass local handles to scheduled tasks

A local handle is shareable, so it can be passed as a task argument. The task sees the contents selected by its own execution scope. Passing the handle does not send the caller's current local values along with it.

```ruby
context              = Farce::Local::Map.new(scope: :fiber)
context[:request_id] = :caller
results              = Farce::Port.new
scheduler            = Farce::Scheduler.new
worker               = scheduler.launch_thread

[:upload, :download].each do |request_id|
  scheduler.schedule(context, results, request_id) do |local, outbox, id|
    before             = local.empty?
    local[:request_id] = id
    outbox.send([id, before])
  end
end

received = [results.receive, results.receive].sort
received             # => [[:download, true], [:upload, true]]
context[:request_id] # => :caller
scheduler.close
worker.join
results.close
```

Use task arguments for incoming request data, then set up local context inside the task. If child fibers should participate in that same context, consider `:fiber_storage` and establish an explicit inheritance boundary.

### Coordinate changes within a shared scope

Ractor and thread-group scopes can be used by several threads at once. Use the container's coordinated operations for compound changes. Retrieving a mutable value does not make later edits to that object synchronized.

```ruby
completed = Farce::Local::Atom.new(0, scope: :ractor)
threads = 4.times.map do
  Thread.new do
    100.times { completed.update { |count| count + 1 } }
  end
end
threads.each(&:join)

completed.value # => 400
```

Likewise, use `Map#update` for a coordinated replacement or a lease for exclusive resource use. Choose the scope first, then the operation that provides the coordination callers in that scope need.

## Under the hood

### Resolve the current backing object on every operation

Most local classes share the `Farce::Local::Scoped` implementation. The shareable handle stores its scope and construction settings. A private storage table maps that handle to a backing object for the current scope. A map operation goes to a map, a queue operation to a queue, and a lazy read to a cached local value.

| Selected scope | How Farce finds the storage |
| --- | --- |
| `:ractor` | The current Farce Ractor. |
| `:thread_group` | The current thread's group within the current Ractor. |
| `:thread` | The current logical thread. |
| `:fiber` | The current fiber. |
| `:fiber_storage` | A Farce storage entry in `Fiber[...]`. |

There is one backing object per handle in each selected storage table. Two different local maps remain independent even when they have the same scope. These tables are internal details. Application code should use the local container's public methods.

```ruby
left       = Farce::Local::Map.new(scope: :thread)
right      = Farce::Local::Map.new(scope: :thread)
left[:key] = :value

left[:key]  # => :value
right[:key] # => nil
```

### Local handles can be garbage collected

Farce keeps local handles as weak keys in its scope storage. The storage does not keep a handle alive just because it has been used in that scope. Once nothing else references the local instance, it can be garbage collected. Its backing containers and their contents can then be released too, if nothing else retains them. This works even for scopes attached to long-lived workers.

```ruby
cache = Farce::Local::Map.new(scope: :thread)
cache[:buffer] = String.new("temporary output")
cache = nil

# The local handle is now eligible for collection.
# No per-thread storage slot needs to be cleared by name.

# A built-in storage entry retains its value independently of this variable.
buffer = String.new("retained output")
Thread.current.thread_variable_set(:scopes_example_buffer, buffer)
buffer = nil
Thread.current.thread_variable_get(:scopes_example_buffer) # => "retained output"
Thread.current.thread_variable_set(:scopes_example_buffer, nil)
```

Ruby's built-in Ractor, Thread, and Fiber storage holds named entries. Dropping an application reference does not remove those entries or release their values. Clear or replace the entry, or let its owning execution context become collectible. For example, `Ractor[:key] = nil`, `Thread.current[:key] = nil`, and `Fiber[:key] = nil` release those entries' references. See Ruby's [Ractor storage API](https://docs.ruby-lang.org/en/4.0/Ractor.html#method-c-5B-5D-3D) and the Thread and Fiber APIs linked above.

Keep a local handle in a constant or a live application object when you want its state to persist. The weak storage does not discard a handle that your application still retains. As with other Ruby objects, references from closures or stored values can also keep it alive.

### Initial configuration is reused in new scopes

New scopes use the constructor's initial contents and options. They do not clone the latest state of another scope's backing container. Many local containers create their initial backing object during construction and create others on demand. Lazy values and lease resources still wait until needed to run their factories.

```ruby
status = Farce::Local::Atom.new(:idle, scope: :fiber)
status.value = :busy

Fiber.new { status.value }.resume # => :idle
status.value                     # => :busy
```

Farce uses a mode manager to retain shareable construction settings. Non-shareable settings are held in a copy envelope on native Ractors, giving each Ractor a copy when it needs them. This happens for construction data, not for every value later written to a local container. See [transfer modes](modes.md#under-the-hood) for how envelopes work.

### Separate containers can contain the same objects

Within one Ractor, separate scopes may reuse objects from the same decoded construction settings. A fresh backing map therefore does not guarantee a deep copy of all initial values. The two child fibers below have different maps, but their initial array is the same object.

```ruby
state = Farce::Local::Map.new({ items: [] }, scope: :fiber)

first = Fiber.new do
  state[:only_first] = true
  state[:items] << :first
  state[:items]
end.resume

second = Fiber.new do
  [state.key?(:only_first), state[:items]]
end.resume

second[0]                # => false
second[1]                # => [:first]
first.equal?(second[1])  # => true
```

Use a factory when every scope needs fresh mutable values. `Local::Lazy.new(scope: :fiber) { { items: [] } }` builds a new nested array per fiber. Alternatively, start a local map empty and create values through `store_if_absent` in the scope that needs them. On platforms without native Ractors, construction data is not copied across Farce Ractors either, so factories are useful there too.

### Fiber storage inherits a reference to Farce storage

Ruby copies the fiber-storage hash when creating a child with default storage inheritance. It does not deep-copy the objects stored in that hash. Farce keeps a storage object in one entry, so the inherited reference can lead parent and child to the same backing containers.

```ruby
context = Farce::Local::Map.new(scope: :fiber_storage)
context[:phase] = :created

child = Fiber.new { context[:phase] }
context[:phase] = :ready
child.resume # => :ready
```

This is shared context, not a snapshot of the map at fiber creation. A fresh fiber-storage hash selects fresh Farce storage. The choice affects all Farce objects using `:fiber_storage` in that context. Ruby can also inherit fiber storage into new threads, so this scope should not be treated as a strict thread boundary. Use `:thread` when thread identity is the boundary you need.

### Scopes and transfer modes solve different problems

A scope selects which contents a caller accesses. A [transfer mode](modes.md) selects how a non-shareable value is carried or stored. `Farce::Queue.new(mode: :local)` has one queue whose local payloads belong to their originating Ractor. `Farce::Local::Queue.new` has a separate queue for each scope.

```ruby
queue = Farce::Local::Queue.new
queue.push(:main_job)
results = Farce::Port.new

worker = Farce::Ractor.new(queue, results) do |local, outbox|
  outbox.send(local.empty?)
end

results.receive # => true
queue.pop       # => :main_job
worker.join
results.close
queue.close
```

Use a local container for independent state behind a shared handle. Use a regular Farce container when callers in different Ractors need to communicate through the same contents. Choosing a scope does not move data from one scope to another.
