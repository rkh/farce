# Changelog

Farce follows [Semantic Versioning 2.0](http://semver.org/). Any public method on any public class or module documented in the README or via YARD and not declared private is part of the public API.

## Development Releases

### Farce 0.3.0 (2026-10-13)

#### New Features

##### Breaking Changes

* `Abstract::Scheduler` is no longer a superclass of `Pool`. Use `Abstract::Executor` instead.

##### Executor Improvements

`Scheduler` and `Pool` have the following improvements:

* They now support `try_schedule`, which discards tasks and returns `nil` when their internal queues are at capacity.
* They now have `Unshared` and `Local` variants, running in a Ractor-local context (Pool will manage a Thread pool instead of a Ractor pool).

Creates a thread pool with a maximum size of 2 and a queue capacity of 10:

```ruby
# A thread pool local to the current Ractor
thread_pool = Farce::Unshared::Pool.new(max_size: 2, capacity: 10)

# this should only run approximately 10 tasks on CRuby
500.times { thread_pool.try_schedule { puts "Task executed" } }
```

##### Tasks

A new class, `Task`, has been introduced to represent asynchronous tasks that can be scheduled and executed within Farce's executor framework,
executed manually, or handed off to any other executor supporting procs or callable objects.

```ruby
task = Farce::Task.schedule do
  puts "Task started"
  sleep 1
  :success
ensure
  puts "Task finished"
end

task.alive? # => true
task.value  # => :success (blocks until the task completes)
```

#### Bug Fixes

* Calling `wait_*` methods on atoms on JRuby no longer blocks a fiber scheduler.

### Farce 0.2.0 (2026-10-11)

#### New Features

##### Waiting on Flags

You can now wait for a `Farce::Flag` or `Farce::Local::Flag` to change its value:

```ruby
flag = Farce::Flag.new

Thread.new do
  flag.wait_until_set
  puts "Flag has been activated!"
end

flag.set
```

##### Timer Queue Entries

`TimerQueue#push` and `TimerQueue#try_push` now return a `TimerQueue::Entry` object on a successful push.
This allows you to cancel a scheduled value using the returned entry:

```ruby
queue = Farce::TimerQueue.new
entry = queue.push(:work, delay: 60)
entry.delete # => true
```

##### Expanded Vector Functionality

Improved Array compatibility for `Vector`, `Strict::Vector`, `Unshared::Vector`, and `Local::Vector`:

* Added `to_ary`, `delete`, and `delete_if`.
* Added range and start/length indexing, slice assignment, multiple-value `push` and `append`, and `pop(count)`.
* Added `shift`, `unshift`, `prepend`, `insert`, `delete_at`, `slice!`, `replace`, and `fill`.
* Added `map!`, `collect!`, `keep_if`, `select!`, `filter!`, `reject!`, `compact!`, and `uniq!`.
* Added `reverse!`, `rotate!`, `shuffle!`, `sort!`, `sort_by!`, and `flatten!`.
* Added `flatten`, `transpose`, `product`, `combination`, `repeated_combination`, `permutation`, and `repeated_permutation`.
* Added lexicographic `<=>`. Equality and hashing continue to use object identity.

##### Miscellaneous

* Unshareable objects may now be frozen.
* Trying to make an unshareable object shareable raises a better error message now (`Ractor::Error` with a descriptive message, instead of a `NoMethodError`).
* Added a new transfer mode: `:marshal`, which will copy objects between Ractors using Ruby's [Marshal](https://docs.ruby-lang.org/en/4.0/Marshal.html) serialization.

#### Bug Fixes

* Improve compatibility with other gems modifying `Kernel#require`, work around an issue with Ruby 4.0's runtime ractor require patch and alias methods chains not working nicely with `Module#prepend`.

#### Performance Improvements

##### Rework CRuby native extension

Incorporated the advice from ["Tips for updating Ruby C extensions for efficiently using Ruby 4 VM APIs"](https://github.com/ruby/ruby/blob/master/doc/efficient_extensions.md).

With this change, all long-living Farce objects can be compacted and moved to old GC generations. This was not the case previously for maps and vectors that had snapshots taken of them (either for iteration or for transactions). These ended up being permanently kept in young generations. A long-living map or vector would therefore cause frequent GC runs to be quite expensive.

| Operation                                           | Before  | After   | Change      |
| --------------------------------------------------- | ------- | ------- | ----------- |
| `Map#each` over 1024 entries                        | 34.1 μs | 35.2 μs | 3% slower   |
| Transaction with a map with 16 entries              | 25.2 μs | 25.3 μs | 0.4% slower |
| Transaction with a map with 1024 entries            | 26.7 μs | 29.2 μs | 9% slower   |
| Transaction with a vector with 10,000 entries       | 26.1 μs | 29.4 μs | 13% slower  |
| GC while keeping a vector with 10,000 entries alive | 67.6 μs | 28.6 μs | 58% faster  |

Beyond these specific cases:
* Other iteration methods will have a similar performance impact to `Map#each` (for instance, `Map#transform_values`).
* Methods not involving iterations, like reading or writing a specific map entry, do not show any measurable performance impact.

Measurements were taken on CRuby 4.0.7 (arm64-darwin23) with YJIT enabled. Measurements taken against Ruby's main branch show similar results.

#### Other changes

* Avoid circular require warnings when automatically loading third-party integrations.
* Do not install a require hook if automatic integration loading is disabled.

### Farce 0.1.0 (2026-10-09)

Initial release.
