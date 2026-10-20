<!--
# @title Compatibility and Dependencies
-->

# Compatibility and Dependencies

Farce has no mandatory dependencies beyond Ruby itself.

## Ruby

Each Farce release is expected to be compatible with:

* The [latest patch release](https://www.ruby-lang.org/en/downloads/releases/) for each [CRuby](https://www.ruby-lang.org/en/) version [still receiving bug fixes](https://www.ruby-lang.org/en/downloads/branches/).
* Ruby's [master branch](https://github.com/ruby/ruby/tree/master) at the time of release (i.e., the upcoming major version of CRuby).
* The latest stable release of [JRuby](https://www.jruby.org/) and [TruffleRuby](https://truffleruby.dev/) (both in native and GraalVM modes).

Moreover:

* Dropping support for a CRuby version is only done in major releases.
* If support for an older CRuby version is dropped, Farce will still backport security fixes for at least as long as that CRuby version is [still receiving security fixes](https://www.ruby-lang.org/en/downloads/branches/).

## Optional Dependencies

Farce's optional [integrations](integrations.md#integrations) depend on external libraries. Automated tests only run against recent versions of these libraries, but the code is written to be compatible with as wide a range as possible.

Farce should be compatible with these versions:

| Gem               | Minimum Version | Release Date |
|-------------------|-----------------|--------------|
| `ractor-tmvar`    | 0.4.0           | 2026-10-11   |
| `msgpack`         | 1.7.0           | 2023-03-29   |
| `concurrent-ruby` | 1.1.8           | 2021-01-20   |
| `dry-types`       | 1.0.0           | 2019-04-23   |
| `activesupport`   | 5.1.0           | 2017-04-27   |
| `oj`              | 2.8.1           | 2014-04-21   |
| `bson`            | 2.0.0           | 2013-12-02   |
| `psych`           | 1.1.0           | 2011-03-30   |

Any version of `cbor`, `json`, `ractor-sharing`, `sorted_set`, and `weakref` should be supported.

If you want to use any of these in a version that is incompatible with Farce, you can [disable automatic integration loading](integrations.md#disable-automatic-loading).

## Similar Projects

* [ractor-shim](https://github.com/eregon/ractor-shim/) provides similar functionality to `Farce::Ractor`. See [the comparison document](gems/ractor-shim.md) for more details.
* [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) provides a more complete set of concurrency primitives than Farce, but is not compatible with Ractors.
* [ratomic](https://mperham.github.io/ratomic/) has overlapping functionality with Farce for basic data structures like maps, counters, and queues.
* [ractor_safe](https://github.com/jhawthorn/ractor_safe/) has overlapping functionality with Farce for basic data structures like maps, counters, and queues.
* [ractor-sharing](https://github.com/ko1/ractor-sharing) has overlapping functionality with Farce for basic data structures like maps, counters, queues, as well as software transactional memory.

All of the above projects can safely be used alongside Farce in the same application.

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

### Fiber schedulers and Ractors don't play nice on Ruby 3.4

Fiber schedulers running in a non-main Ractor have a chance of causing a segmentation fault on x86_64 Linux with Ruby 3.4.11 and earlier.

This issue is [unrelated to Farce itself](https://gist.github.com/rkh/f330bd5c4accc9718f5ca227ae020c94) and typically only surfaces irregularly under a high number of Ractor shutdowns.
It does however surface from time to time when running the Farce test suite on affected Ruby versions and platforms.

Installing and loading Farce, using Farce data structures, etc, does not increase the likelihood of encountering this issue.

### GC related tests are flaky in certain environments

Garbage collection related tests may exhibit flakiness on some Ruby versions and platforms. This can lead to unexpected failures when running the test suite.

## Read Next

[README](../README.md#features) · [Installation](installation.md) · [Integrations](integrations.md)
