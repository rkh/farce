# Changelog

Farce follows [Semantic Versioning 2.0](http://semver.org/). Any public method on any public class or module documented in the README or via YARD and not declared private is part of the public API.

## Upcoming Releases

### Farce 0.2.0 (Unreleased)

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

## Development Releases

### Farce 0.1.0 (2026-10-09)

Initial release.
