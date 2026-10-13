<!--
# @title Scheduling Code
-->

# Scheduling Code

Use Farce to schedule background work, reuse workers for parallel computation, or dispatch calls to the main Ractor. Tasks retain results, while schedulers and pools control where work runs.

## `Farce.on_main`

Some code has to be executed on the main Ractor, especially when working with legacy code that doesn't support Ractors.

You can pass a block to `Farce.on_main` to run code on the main Ractor. The method call will block until the code has been executed.

```ruby
# most of concurrent-ruby is not usable outside of the main-ractor
$tvar = Concurrent::TVar.new(0)

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

## `Farce.in_parallel`

As you can see in the [shared-state example](introduction.md#example), creating Ractors ad hoc because you want to run something in parallel is quite expensive.

Use `Farce.in_parallel` to schedule parallel work. On CRuby, it manages a shared [Ractor pool](#ractor-pools), starting workers when the current ones cannot keep up with the load, up to the number of CPU cores. It shuts unused workers down after some inactivity. On JRuby and TruffleRuby, it starts a new thread for each task.

```ruby
input = "this is my input"
Farce.in_parallel(input) { expensive_computation(it) }
```

Like most of Farce, this is completely opt-in. If you never use this feature, no pool is being set up and no extra Ractors are created.

## `Farce.schedule`

`Farce.in_parallel` might not always be what you want. Maybe you are working on a library and don't want to dictate a concurrency model?

You can use `Farce.schedule`, which will automatically figure out how to run code off-band. You can use `mode: :local` to force execution inside the current Ractor (which it will prefer by default if there already is some scheduler running, but not enforce).

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

## Schedulers

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
scheduler.close
Fiber.set_scheduler(nil) # drain scheduled work and detach the scheduler
```

Scheduler instances are Ractor-shareable.

## Ractor Pools

`Farce::Pool` implements the same scheduling interface, but manages a pool of Ractors. This is what [`in_parallel`](#farcein_parallel) uses under the hood.

```ruby
# At least four Ractors, up to ten. Launch a new one if a task waits longer than 100 milliseconds.
pool = Farce::Pool.new(min_size: 4, max_size: 10, grow_after: 0.1)
pool.schedule { puts "Hello from the pool!" }
```

## Tasks

If you want to retrieve the result of an asynchronous operation, or monitor if it is still running, you can use `Farce::Task`:

```ruby
task = Farce::Task.schedule(1, 2) do |a, b|
  sleep 1 # simulate intense computation
  a + b
end

task.alive? # => true
task.value  # => 3 (after approximately 1 second)
task.join   # would block, but doesn't, as the task has already completed
```

Tasks can also be created without immediately scheduling them, allowing you to control when and how they are executed:

```ruby
task = Farce::Task.new { :success }
task.alive?     # => true
task.value(0.1) # => nil (after 100 milliseconds)

Farce.schedule(&task)
task.value # => :success
```

This allows you to use third-party executors:

```ruby
require "concurrent"
executor = Concurrent.global_fast_executor
task     = Farce::Task.new { :success }
executor.post(&task)

task.value # => :success
```

## Third-Party Fiber Schedulers

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

## Read Next

[README](../README.md#features) · [Concurrency](concurrency.md) · [Shims, Polyfills, and Extensions](shims.md)
