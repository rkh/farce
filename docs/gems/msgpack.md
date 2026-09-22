<!--
# @title Gem: MessagePack
-->

# Farce / [MessagePack](https://github.com/msgpack/msgpack-ruby)

Use MessagePack to store or send Farce values. Add `msgpack` to your Gemfile
and load it:

```ruby
require "msgpack"
require "farce"

jobs  = Farce::Vector.new(["build", "test"])
bytes = jobs.to_msgpack # or: MessagePack.pack(jobs)
```

Vectors, maps, sets, atoms, counters, and flags support `to_msgpack`, including
nested values and their Farce variants.

## Restoring Farce objects

By default, unpacking returns ordinary Ruby values: arrays for vectors and sets,
hashes for maps, integers for counters, booleans for flags, and the stored values
for atoms. This makes the data easy to use outside Farce:

```ruby
MessagePack.unpack(bytes) # => ["build", "test"]
```

To restore Farce objects instead, use a factory for both packing and unpacking:

```ruby
factory = Farce::MessagePack.factory
copy = factory.load(factory.dump(jobs))
copy.class # => Farce::Vector
copy.to_a  # => ["build", "test"]
```

The factory also restores nested Farce objects. It does not change
`MessagePack.pack` or `to_msgpack`. Restored objects contain the current values,
and counters retain their initial value for `reset`. Other settings, such as
transfer modes and local scopes, use constructor defaults unless configured below.

## Custom factories

Choose extension IDs to fit your application's protocol:

```ruby
factory = Farce::MessagePack.factory(types: {
  Farce::Vector  => 40,
  Farce::Counter => 41
})
```

`types:` replaces the default registrations, which use IDs 0 through 5 for
Vector, Map, Counter, Flag, Atom, and Set, respectively. Both ends must use the
same registrations. Register variants explicitly to restore their specific classes.

You can also add Farce types to an existing MessagePack factory and supply
constructor options for restored objects:

```ruby
factory = MessagePack::Factory.new
Farce::MessagePack.register_type(factory, 60, Farce::Vector, mode: :make_shareable)
Farce::MessagePack.register_type(factory, 61, Farce::Local::Counter, scope: :fiber)
```

Use unused IDs from 0 through 127. Nested values use the same factory, including
your application's other registered types.
