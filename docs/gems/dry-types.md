<!--
# @title Gem: dry-types
-->

# Farce / [dry-types](https://dry-rb.org/gems/dry-types/)

The opt-in dry-types integration validates input and constructs Farce values
from the result. It is useful when parsed input is headed to concurrent workers
or Farce-backed application state.

Add `dry-types` to your application and include both type imports:

```ruby
require "dry-types"
require "farce"

module Types
  include Dry.Types()
  include Farce.DryTypes()
end
```

`Farce.DryTypes()` follows the preceding `Dry.Types()` import. Root Farce types
use the corresponding dry default types. Namespaces and aliases gain matching
Farce constants without replacing existing dry types. Loading Farce by itself
does not load dry-types.

The imported constants construct new Farce objects. Use an instance type to
check an existing Farce object without conversion:

```ruby
module Types
  VectorInstance = Instance(Farce::Vector)
end

Types::VectorInstance.try(Farce::Vector.new).success? # => true
Types::VectorInstance.try([]).failure?                # => true
```

## Vectors

Use `Vector.of` to apply a member type before constructing the vector:

```ruby
module Types
  IntegerVector = Vector.of(Coercible::Integer)
end

numbers = Types::IntegerVector[["1", 2]]
numbers.class # => Farce::Vector
numbers.to_a  # => [1, 2]
numbers.mode  # => :copy
```

The bare `Vector` accepts any Array members. Imported dry namespaces control
the outer native input in the same way as their Array type:

```ruby
Types::Vector.try("one").failure?    # => true
Types::Coercible::Vector["one"].to_a # => ["one"]
```

The resulting values compose with optional types, constraints, `try`, and
failure blocks:

```ruby
Types::IntegerVector.optional[nil] # => nil

result = Types::IntegerVector.try(["invalid"])
result.failure? # => true

Types::IntegerVector.(["invalid"]) { |partial| [:invalid, partial] }
# => [:invalid, ["invalid"]]
```

Member and source coercion complete before Farce construction. Their failure
blocks receive dry-types' partial native value, never a partially initialized
Farce collection. Constraints added to a collection type run on its constructed
Farce result. A size constraint on a Set therefore observes deduplication.

dry-types callable defaults return the block result directly. Construct the
typed value inside the block when each use needs a fresh Farce collection:

```ruby
module Types
  EmptyIntegerVector = IntegerVector.default { IntegerVector[[]] }
end

Types::EmptyIntegerVector[].class  # => Farce::Vector
Types::EmptyIntegerVector[].empty? # => true
```

## Maps and schemas

Use `Map.map` for homogeneous key and value types:

```ruby
module Types
  ScoreMap = Map.map(String, Coercible::Integer)
end

scores = Types::ScoreMap["Ada" => "10", "Grace" => 12]
scores.class # => Farce::Map
scores.to_h  # => {"Ada" => 10, "Grace" => 12}
```

dry-types rejects keys that collide after coercion. The integration also
rejects identity Hash input with structurally equal keys because a structural
Farce Map could otherwise drop an entry.

Use `Map.schema` for fixed keys, defaults, key transforms, and nested types:

```ruby
module Types
  Batch = Map.schema(
    name: String,
    ids: IntegerVector,
  ).strict
end

batch = Types::Batch[name: "nightly", ids: ["10", 20]]
batch[:name]      # => "nightly"
batch[:ids].class # => Farce::Vector
batch[:ids].to_a  # => [10, 20]
```

Schema chaining and `with_key_transform` or `with_type_transform` retain Farce
construction. A non-strict schema omits unknown keys. Call `.strict` when
unknown keys should fail.

## Sets

`Set.of` applies its member type before membership removes duplicates:

```ruby
module Types
  IntegerSet = Set.of(Coercible::Integer)
end

values = Types::IntegerSet[["1", 1, "2"]]
values.class     # => Farce::Set
values.to_a.sort # => [1, 2]
```

It accepts Arrays and Ruby Sets. The bare `Set` accepts any Array members.

## Counters and flags

`Counter` uses the imported dry `Integer` type. `Flag` uses the imported dry
`Bool` type:

```ruby
counter = Types::Coercible::Counter["3"]
counter.class # => Farce::Counter
counter.value # => 3

flag = Types::Params::Flag["yes"]
flag.class # => Farce::Flag
flag.value # => true
```

A namespace only gains a Farce type when it has the corresponding dry type.
For example, dry-types defines `Coercible::Integer` but no `Coercible::Bool`,
so `Types::Coercible::Counter` exists while `Types::Coercible::Flag` does not.

The dry type validates the initial scalar. Counter and Flag retain their normal
Farce APIs after construction.

## Atoms

The bare `Atom` accepts any initial value. Use `Atom.of` to validate or coerce
the initial contents:

```ruby
module Types
  IntegerAtom = Atom.of(Coercible::Integer)
end

atom = Types::IntegerAtom["4"]
atom.class # => Farce::Atom
atom.value # => 4
```

The type applies only at construction. Later writes use the normal Atom API and
are not revalidated:

```ruby
atom.value = "later"
atom.value # => "later"
```

Nil as Atom contents differs from an optional Atom constructor:

```ruby
Types::Atom[nil].value                             # => nil
Types::Atom.of(Types::Integer.optional)[nil].value # => nil
Types::Atom.of(Types::Integer).optional[nil]       # => nil
```

The first two expressions construct an Atom containing nil. The last expression
returns nil without constructing an Atom.

## Dry imports and Farce variants

With no dry namespace arguments, `Farce.DryTypes()` inherits the closest
`Dry.Types()` import. With no preceding import, it uses the same strict defaults
as `Dry.Types()`. Pass dry namespace arguments, `default:`, and aliases to
select an independent source using the normal `Dry.Types()` rules:

```ruby
module CoercingTypes
  include Dry.Types()
  include Farce.DryTypes(:strict, :coercible, default: :coercible)
end

CoercingTypes::Vector["1"].to_a # => ["1"]
```

The dry namespace controls validation and coercion of native input. `variant:`
selects the Farce class produced after that succeeds:

```ruby
module LocalTypes
  include Dry.Types(default: :coercible)
  include Farce.DryTypes(variant: :local, scope: :fiber)
end

vector = LocalTypes::Vector["job"]
vector.class # => Farce::Local::Vector
vector.scope # => :fiber
```

Supported variants are `:shared`, `:strict`, `:unshared`, and `:local`.
`:shared` is the default and accepts `mode:`. `:local` accepts `scope:`.
Strict and Unshared variants accept neither option. Farce's `:strict` variant
and dry-types' `Strict` namespace configure separate parts of the conversion.

| `variant:` | Constructed classes |
| --- | --- |
| `:shared` | `Farce::Vector`, `Farce::Map`, `Farce::Set`, `Farce::Counter`, `Farce::Flag`, `Farce::Atom` |
| `:strict` | `Farce::Strict::Vector`, `Farce::Strict::Map`, `Farce::Strict::Set`, `Farce::Strict::Atom` |
| `:unshared` | `Farce::Unshared::Vector`, `Farce::Unshared::Map`, `Farce::Unshared::Set` |
| `:local` | `Farce::Local::Vector`, `Farce::Local::Map`, `Farce::Local::Set`, `Farce::Local::Counter`, `Farce::Local::Flag`, `Farce::Local::Atom` |

The integration imports only classes that Farce provides for the selected
variant. Strict has an Atom but no Counter or Flag. Unshared has none of these
three scalar-backed types.

For a single shared collection type, use `.with(mode: ...)`:

```ruby
module Types
  LocalValueVector = Vector.with(mode: :local)
end

payload = []
vector = Types::LocalValueVector[[payload]]
vector[0].equal?(payload) # => true
```

The supported shared modes are `:copy`, `:local`, `:make_shareable`,
`:shareable_copy`, and `:raise`. They apply to collections and Atom. Counter and
Flag have no transfer mode. `:move` is rejected because dry-types creates and
examines intermediate values during coercion.

## Farce input and ownership

Mode-free Strict, Unshared, and Local Farce collections can be converted
directly. Construction always returns a fresh configured variant.

Mode-backed `Farce::Vector`, `Farce::Map`, and `Farce::Set` input is rejected
before traversal. Materialize one explicitly when reading it is intended:

```ruby
source = Farce::Vector.new(["1"])
converted = Types::IntegerVector[source.to_a]
converted.to_a # => [1]
```

The explicit read establishes where transfer and ownership happen. This rule
also applies when the container's default mode is `:copy` because an individual
entry might have been inserted with `mode: :move`.

Vector materialization uses its normal snapshot. Map and set materialization
uses normal iteration and is not a globally atomic snapshot during concurrent
mutation. Validation describes the values processed by that call. Later writes
through the Farce API are not revalidated. Atom input is treated as its payload
and is never implicitly read from an existing Atom. Mutable values keep the
guarantees of the selected Farce mode. The dry type descriptor is application
configuration and is not promised to be Ractor-shareable.
