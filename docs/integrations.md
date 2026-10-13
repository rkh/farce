<!--
# @title Integrations
-->

# Integrations

Farce ships with a couple of integrations that are automatically loaded if and only if both farce and the other gem have also been loaded (it does not automatically load these gems, even if they are part of the current bundle). This is load-order independent.

## Active Support

The Active Support integration adds the following methods:

* For all data structures: `as_json`, `blank?`, `deep_dup`, and `duplicable?`
* For maps: `assert_valid_keys`, `compact_blank`, `reverse_merge`, `stringify_keys`, `symbolize_keys`, `to_param`, `to_query`, `with_defaults`, and `with_indifferent_access`
* For vectors: `compact_blank`, `excluding`, `from`, `including`, `inquiry`, `in_groups`, `in_groups_of`, `in_order_of`, `maximum`, `minimum`, `pluck`, `pick`, `split`, `to`, `to_fs`, `to_param`, `to_sentence`, `to_query`, `to_xml`, `second`, `third`, `fourth`, `fifth`, `forty_two`, `third_to_last`, and `second_to_last`

And the following features:
* Converting `ActiveSupport::HashWithIndifferentAccess` to a map via [`Farce.enfarce`](utilities.md#top-level-methods) will set up the correct key normalization.
* [`Farce::Clock`](utilities.md#additional-classes) understands `ActiveSupport::Duration`.

Other methods are already being inherited by various objects via `Object`, `Enumerable` for vectors, sets, and maps, `Numeric` for counters, etc.

```ruby
require "active_support/all"
require "farce"

map     = Farce::Map.new.with_indifferent_access
map[:a] = 10

map.blank? # => false
map["a"]   # => 10
```

The integration isn't triggered by loading `active_support`, but instead looks for `active_support/core_ext`, so you should require that (or `active_support/all`, which in turn requires it).

## Dry Types

Adds support for Farce [data structures](data-structures.md#data-structures) to [Dry Types](https://hanakai.org/learn/dry/dry-types):

```ruby
require "dry-types"
require "farce"

module Types
  include Dry.Types()
  include Farce.DryTypes()

  IntegerVector = Vector.of(Coercible::Integer)
end

numbers = Types::IntegerVector[["1", 2]]
numbers.class # => Farce::Vector
numbers.to_a  # => [1, 2]
```

Check out the [dedicated documentation](gems/dry-types.md) to learn more.

## JSON, YAML, etc

It ships integrations for serialization (and some deserialization) with the following gems:

* For BSON support: `bson`
* For CBOR support: `cbor`
* For JSON support: `json` (from the Ruby standard library), `oj`, and `yajl`
* For MessagePack: `msgpack`. See the [detailed documentation](gems/msgpack.md)
* For YAML: `psych` (from the Ruby standard library)

Example:

```ruby
require "json"
require "farce"

map = Farce::Map.new
map[:x] = Farce::Vector[1, 2, 3]
map.to_json # => '{"x":[1,2,3]}'
```

## Concurrent Ruby

The integration adds the following features if [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) has been loaded:

* [Transaction support for `Concurrent::TVar`](concurrency.md#tvars)
* Automatic conversion of `Concurrent::Map` instances to [maps](data-structures.md#maps) via [`Farce.enfarce`](utilities.md#top-level-methods).

## Ractor Sharing

The integration adds the following features if [ractor-sharing](https://github.com/ko1/ractor-sharing) has been loaded:

* [Transaction support for `Ractor::TVar`](concurrency.md#tvars)
* Support for traversing and deep freezing `Ractor::TVar`, `Ractor::LockVar`, `Ractor::LockHash`, and `Ractor::KeyLockHash`
* Support for converting `Ractor::LockHash` and `Ractor::KeyLockHash` to [maps](data-structures.md#maps) via [`Farce.enfarce`](utilities.md#top-level-methods).

## Additional Integrations

* [`sorted_set`](https://github.com/knu/sorted_set): Add support for walking and converting them.
* [`ractor-tmvar`](https://github.com/yoshitsugu/ractor-tmvar): Adds transaction support.
* [`weakref`](https://github.com/ruby/weakref): Add support for walking and converting them.

## Disable Automatic Loading

You can set the environment variable `FARCE_AUTOLOAD_INTEGRATIONS` to `false` or `0` to disable automatic integration loading.

Or you can use `Farce.configure` to disable it. But you may have to do so before loading `farce` unless you're absolutely certain the other gem has not yet been loaded:

```ruby
# This could go in an initializer
require "farce/config"

Farce.configure do |config|
  config.autoload_integrations = false
end

require "farce"

# you now need to load any integrations you might want explicitly
# these are available via "farce/integrations/#{gem_name}"
require "farce/integrations/json"
require "farce/integrations/concurrent"
```

## Read Next

[README](../README.md#features) · [Compatibility and Dependencies](compatibility.md) · [Utilities and Custom Classes](utilities.md)
