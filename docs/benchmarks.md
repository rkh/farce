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

In the producer/consumer workload in `benchmark/queue.rb`, Ruby's built-in `Thread::Queue` and `Thread::SizedQueue` remain the fastest, but they do not support ractors.

 Implementation                | Performance | Notes
-------------------------------|-------------|-------------
 `Thread::Queue`               | Fastest     | no ractor support
 `Thread::SizedQueue`          | 1.4x slower | no ractor support
 `Farce::StrictQueue`          | 1.5x slower | only allows sharable objects
 `Farce::Queue`                | 2.1x slower |
 `Ratomic::Queue`              | 8.7x slower | breaks ractor isolation
 `RactorQueue`                 | 27x slower  | breaks ractor isolation
 `Ractor::Port` (multiplexing) | 100x slower |

## Priority queue performance

Many gems implement a priority queue or comparable data structure.
Farce's implementation is the only one that allows cross-ractor communication.
The below numbers compare non-blocking APIs, as only Farce implements a blocking API as well.

<table>
  <thead>
    <tr>
      <th colspan="2"></th>
      <th colspan="2">CRuby</th>
      <th colspan="2">JRuby</th>
    </tr>
    <tr>
      <th>↓ Gem</th>
      <th>Insertion order →</th>
      <th>Random</th>
      <th>Descending</th>
      <th>Random</th>
      <th>Descending</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td colspan="2">farce 0.1.0</td>
      <td>fastest</td>
      <td>fastest</td>
      <td>fastest</td>
      <td>fastest</td>
    </tr>
    <tr>
      <td colspan="2"><a href="https://github.com/mame/rbtree">rbtree</a> 0.4.7</td>
      <td>1.1x slower</td>
      <td>1.2x  slower</td>
      <td>–</td>
      <td>–</td>
    </tr>
    <tr>
      <td colspan="2"><a href="https://github.com/boborbt/priority_queue_cxx">priority_queue_cxx</a> 0.3.7</td>
      <td>1.7x slower</td>
      <td>1.7x slower</td>
      <td>–</td>
      <td>–</td>
    </tr>
    <tr>
      <td colspan="2"><a href="https://github.com/socketry/io-event">io-event</a> 1.21.1</td>
      <td>2.6x slower</td>
      <td>3.9x slower</td>
      <td>1.3x slower</td>
      <td>1.7x slower</td>
    </tr>
    <tr>
      <td colspan="2"><a href="https://github.com/rubyworks/pqueue">pqueue</a> 2.2.0</td>
      <td>9.5x slower</td>
      <td>8.0x slower</td>
      <td>2.2x slower</td>
      <td>1.9x slower</td>
    </tr>
    <tr>
      <td colspan="2"><a href="https://github.com/matiasbattocchia/lazy-priority-queue">lazy_priority_queue</a> 0.1.1</td>
      <td>9.9x slower</td>
      <td>7.9x slower</td>
      <td>3.9x slower</td>
      <td>3.2x slower</td>
    </tr>
    <tr>
      <td colspan="2"><a href="https://github.com/philiprehberger/rb-priority-queue">philiprehberger-priority_queue</a> 0.5.0</td>
      <td>13x slower</td>
      <td>19x slower</td>
      <td>7.6x slower</td>
      <td>11x slower</td>
    </tr>
  </tbody>
</table>
