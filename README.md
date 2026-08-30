# Farce: Fiber and Ractor Compatibility Enabler

## Compatibility and Dependencies

Farce has no mandatory dependencies beyond Ruby itself.

### Ruby

Upon release of the latest version of Farce, it assumes to be compatible with:

* The [latest patch release](https://www.ruby-lang.org/en/downloads/releases/) for each [CRuby](https://www.ruby-lang.org/en/) version [still receiving bug fixes](https://www.ruby-lang.org/en/downloads/branches/).
* Ruby's [master branch](https://github.com/ruby/ruby/tree/master) at the time of release (ie the upcoming major version of CRuby).
* The latest stable release of [JRuby](https://www.jruby.org/) and [TruffleRuby](https://truffleruby.dev/) (both in native and GraalVM modes).

Moreover:

* Dropping support for a CRuby version is only done in major releases.
* If support for an older CRuby version is dropped, Farce will still backport security fixes for at least as long as that CRuby version is [still receiving security fixes](https://www.ruby-lang.org/en/downloads/branches/).

### Similar Projects

* [ractor-shim](https://github.com/eregon/ractor-shim/) provides similar functionality to `Farce::Ractor`. See [the comparison document](docs/gems/ractor-shim.md) for more details.
* [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) provides a more complete set of concurrency primitives than Farce, but is not compatible with Ractors.
* [ratomic](https://mperham.github.io/ratomic/) has overlapping functionality with Farce. See [the comparison document](docs/gems/ratomic.md) for more details.

All of the above projects can safely be used alongside Farce in the same application.

## Installation

### Globally

To install Farce globally, you can use the following command:

```console
$ gem install farce
```

### As a project dependency

If you want to use Farce directly in your project, it is recommended to do so via [Bundler](https://bundler.io).
Add Farce to your `Gemfile`:

```ruby
source "https://gem.coop" # or "https://rubygems.org"

gem "farce"
```

Then run `bundle install` to install the dependencies.

### As a library dependency

Farce's main purpose is to be used as a dependency for other libraries. As such, it will most commonly be added as a [runtime dependency](https://guides.rubygems.org/specification-reference/#add_dependency) to your gemspec:

```ruby
Gem::Specification.new do |spec|
  # ...
  spec.add_dependency "farce"
end
```

### Local setup

If you want to work on Farce itself, you can clone the repository and use [mise](https://mise.jdx.dev) to set everything up:

For more details, or if you aren't using mise, check the [contribution guidelines](CONTRIBUTING.md).

```console
$ git clone https://github.com/rkh/farce.git # prefix with `jj` if you're using Jujutsu
$ cd farce
$ mise run
```

### Loading Farce
You should always require `farce`, rather than any other files in `lib`. Other files are not intended as entry points.

```ruby
require "farce"
```

Constants (classes, modules, etc.) under the `Farce` namespace are loaded lazily (thread- and ractor-safe), so there is no
need to specifically load any particular file.
