# Farce: Fiber and Ractor Compatibility Enabler

## Installation

> [!NOTE]
> You should always require `farce`, rather than any other files in `lib`. Other files are not intended as entry points.
>
> ```ruby
> require "farce"
> ```
>
> Constants (classes, modules, etc.) under the `Farce` namespace are loaded lazily (thread- and ractor-safe), so there is no
> need to specifically load any particular file.

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
