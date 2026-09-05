<!--
# @title Benchmarks
-->

# Benchmarks

Farce also aims to be fast and efficient, aiming for anywhere between a minimal overhead to outperforming other options.

Any numbers quoted here are to be taken with a grain of salt:

* They are based on micro-benchmarks, which may not reflect real-world performance.
* They are momentary snapshots. Gems and Ruby implementations are constantly evolving,
  so these numbers may not be accurate in the future.
* Concrete numbers are largely measured on a local machine, which may not reflect your deployment environment.

You should measure the performance of your own application under realistic conditions.

## Counter performance

> [!CAUTION] 
> If counter performance is your application's bottleneck, **Ruby might not be the right choice for you**.

### CRuby (4.0)

 Implementation      | Increment   | Read value     | Integer size | Note
---------------------|-------------|----------------|--------------|-------
 farce               | fastest     | fastest        | 64-bit       |
 concurrent-ruby-ext | 1.2x slower | same-ish       | 32-bit       | no ractor support
 ratomic             | 1.5x slower | 1.6x slower    | 64-bit       | no overflow protection
 concurrent-ruby     | 12x slower  | 5x slower      | 32-bit       | no ractor support

Performance differences between implementations are consistent between single-threaded and multi-threaded benchmarks.

### JRuby

 Implementation      | Increment   | Read value     | Integer size
---------------------|-------------|----------------|--------------
 concurrent-ruby-ext | fastest     | fastest        | 64-bit
 farce               | 1.7x slower | 2.2x slower    | 64-bit
 concurrent-ruby     | 15x slower  | 9x slower      | 32-bit

Farce uses a JVM-specific Ruby implementation, concurrent-ruby uses the same Mutex-based implementation as on other platforms, and concurrent-ruby-ext comes with a Java implementation of an atomic counter (hence also the difference in integer size). The overhead in Farce can largely be attributed to Ruby dispatch overhead.

### TruffleRuby

 Implementation      | Increment   | Read value     | Integer size
---------------------|-------------|----------------|--------------
  farce              | fastest     | fastest        | 64-bit
  concurrent-ruby    | 1.5x slower | 3.5x slower    | 32-bit

TruffleRuby's performance numbers are not as reliable as other Ruby implementations, and may vary significantly between runs, versions, and whether the GraalVM is in use and has warmed up. Neither farce nor concurrent-ruby use a counter written in C, so they should both be fully optimizable by the GraalVM.

## Lock performance

> [!CAUTION] 
> If lock performance is your application's bottleneck, you might want to look into **different data structures**.
> Farce and concurrent-ruby provide plenty of options.

### CRuby

Farce's locks are **between 5% and 10% slower** than `Mutex` for uncontended locks, and stay below a 50% performance penalty for highly contended locks between threads.

### JRuby and TruffleRuby

Farce's locks have identical performance to `Mutex` (as they are a subclass of `Mutex`).

## Queue performance

Nothing beats Ruby's built-in `Queue` and `SizedQueue` for performance, but they do not support ractors. Farce's queues are faster than other options that support ractors, and are the only option that allows sharing of non-sharable objects between ractors, other than Port-multiplexing, which is inefficient.

 Implementation                | Performance | Notes
-------------------------------|-------------|-------------
 `Queue` and `SizedQueue`      | Fastest     | no ractor support
 `Farce::StrictQueue`          | 2.2x slower | only allows sharable objects
 `Farce::Queue`                | 2.7x slower |
 `Ratomic::Queue`              | 6x slower   | breaks ractor isolation
 `RactorQueue`                 | 15x slower  | breaks ractor isolation
 `Ractor::Port` (multiplexing) | 55x slower  |
