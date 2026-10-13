<!--
# @title Concurrency
-->

# Concurrency

Farce is built for concurrent and parallel code execution.

## Locks

Farce ships with two lock classes:
* `Lock` is a drop-in replacement for Ruby's `Mutex`.
* `ReadWriteLock` exposes `with_read_lock`/`with_write_lock` to allow multiple concurrent reads, but exclusive write access.

However, Farce exposes many APIs to eliminate the need for locks altogether.

## Atomic Operations

Farce's [data structures](data-structures.md#data-structures) all expose a range of methods for atomic operations:

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

## Observability and Signaling

All the [data structures](data-structures.md#data-structures) come with extra observability methods, which eliminate the need for using [condition variables](https://docs.ruby-lang.org/en/4.0/Thread/ConditionVariable.html) and [mutexes](https://docs.ruby-lang.org/en/4.0/Thread/Mutex.html).

Even setting aside that these don't work across ractors, this drastically reduces the risk of race conditions (very easy to do if you <u>don't</u> use the same mutex everywhere) or blocking code you don't need to block (very easy to do if you <u>do</u> use the same mutex everywhere).

So instead of sharing locks you can simply wait for a change to happen!

```ruby
# block until the stored value for :key is greater than 10
map.wait_until(:key) { it > 10 }

# block until the value for an atom is no longer :initial
atom.wait_until_changed(:initial)

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

## Transactions

This all sounds great. But you still might want to reach for a lock if you want to modify more than one data structure, if their state is tightly coupled (i.e., updating one without yet updating the other would leave your code in an invalid state).

And a lock is an acceptable solution here. Again, you might want to wrap all the read access in a lock, as there will still be an invalid state. And you also want to roll back any changes already made while holding the lock, if an exception occurs. That is the standard approach in a lot of Ruby code.

Farce offers an alternative. It implements [STM-style transactions](https://en.wikipedia.org/wiki/Software_transactional_memory). You supply a block of code that makes changes to multiple data structures. These changes are only written to these data structures in a commit phase after the block finishes, and they either all succeed or all fail, and they only succeed if the values you've read from any of these data structures haven't changed.

Otherwise the block is rerun.

And this isn't limited to special `TVar` containers, like the APIs provided by concurrent-ruby or ractor-sharing. It supports Farce's main data structures, including [maps](data-structures.md#maps), [vectors](data-structures.md#vectors), [sets](data-structures.md#sets), [atoms](data-structures.md#atoms), and [molecules](data-structures.md#molecules). Moreover, it also supports [mutables](sharing.md#mutables), meaning you can turn most Ruby objects into something transaction compatible fairly easily!

In contrast to other implementations mentioned above, there is no implicit tracking. You need to explicitly add an object to a transaction. This also avoids any uncertainty around nested transactions and unexpected rollbacks.

```ruby
accounts = Farce::Map.new({a: 100, b: 200})

# transfer 80 from :b to :a, but only if both succeed
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

### Maps and Sets

Maps and sets use fine-grained transaction tracking. In the above example, if accounts had another entry, `:c`, its value changing would not impact the transaction at all.

Similarly, if your transaction uses `Transaction::Map#size` as input, only a change in size would trigger a rerun, not a change in content.

This is ideal for scenarios where you use maps as a general data store and sets to track whether an operation was performed on an object (a common pattern to prevent infinite recursion).

### TVars

Farce doesn't come with a `TVar` class. You can just use an [atom](data-structures.md#atoms) instead.

But it does come with built-in support for [`Concurrent::TVar`](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/TVar.html) and [`Ractor::TVar`](https://github.com/ko1/ractor-sharing/blob/main/docs/tvar.md) (assuming you also load these libraries, see [integrations](integrations.md#integrations)).

```ruby
tvar = Concurrent::TVar.new(50)
map  = Farce::Map.new({a: 100, b: 200})

Farce.transaction(map, tvar) do |_, map, tvar|
  # subtract tvar's value from a and b, then set tvar to 0
  # no invalid in-between state is ever visible to anything outside of this transaction
  map[:a] -= tvar.value
  map[:b] -= tvar.value
  tvar.value = 0
end
```

## Read Next

[README](../README.md#features) · [Data Structures](data-structures.md) · [Scheduling Code](scheduling.md)
