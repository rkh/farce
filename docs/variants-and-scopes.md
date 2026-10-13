<!--
# @title Variants and Scopes
-->

# Variants and Scopes

Many classes, including all [data structures](data-structures.md#data-structures), implement multiple variants as separate subclasses within module namespaces.

`Farce::Map`, `Farce::Strict::Map`, `Farce::Local::Map`, and `Farce::Unshared::Map` all support the same API, except that:

* `Farce::Map` accepts an optional `mode` keyword for its initializer and many methods.
* `Farce::Strict::Map` will not allow any non-shareable data to be stored in it. It is slightly faster than `Farce::Map`.
* `Farce::Local::Map` will accept an optional `scope`  keyword for its initializer, and will have different content for each [scope](#provided-scopes).
* `Farce::Unshared::Map` cannot be shared across Ractors, but in turn can store any Ruby object directly, including unshareable objects. It is as fast as `Farce::Strict::Map`.

## Available Variants

> [!TIP]
> Learn more in the dedicated [variants documentation](variants.md).

These variants are provided by Farce:

1. **Default** variants, under the `Farce` namespace:
   * Can **store unshareable values**, usually via [modes](sharing.md#sharing-modes).
     For maps, this is only supported for values. Keys must be shareable.
   * Instances are **Ractor-shareable**.
   * The data structure is **thread-safe**.
2. **Strict** variants, under the `Farce::Strict` namespace:
   * **Forbid unshareable values**
   * Instances are **Ractor-shareable**.
   * The data structure is **thread-safe**.
   * May provide performance benefits over the default variant.
3. **Local** variants, under the `Farce::Local` namespace:
   * Will have **different content** for each [scope](#provided-scopes).
   * Can **store unshareable values**, including unshareable map keys.
   * Instances are **Ractor-shareable**.
   * The data structure is **thread-safe**.
4. **Unshared** variants, under `Farce::Unshared` namespace:
   * Can **store unshareable values**, including unshareable map keys.
   * Instances are **<u>not</u> Ractor-shareable**.
   * The data structure is **thread-safe**.
   * May provide performance benefits over the default variant.
5. **Unsafe** variants, under `Farce::Unsafe` namespace:
   * Same as Unshared, except they do **<u>not</u> guarantee thread-safety**
   * May provide performance benefits over all other variants.
6. **Transaction** variants, under `Farce::Transaction` namespace:
   * Created as mirrors of another object within a [transaction](concurrency.md#transactions).
   * Should not be shared across transaction boundaries.
   * Should not be initialized directly.

The following is true for all variants:
* Blocking operations will suspend a non-blocking fiber, but not block the underlying scheduler.
* The return value of `frozen?` will correctly reflect whether an instance is mutable or not.

However, keep the following in mind:
* Not all classes implement all variants. Check out the [full list](variants.md#classes-implementing-variants)
* Other classes that don't implement variants are also nested under the `Farce` namespace.

## Provided scopes

> [!TIP]
> Learn more in the dedicated [scopes documentation](scopes.md).

Local variants support scopes:

```ruby
map      = Farce::Local::Map.new(scope: :thread)
map[:id] = 1

Thread.new do
  map[:id] = 2
  map[:id] # => 2
end.join

map[:id] # => 1
```

The following scopes are available:

 | Scope              | Description                                                                                      |
 | ------------------ | ------------------------------------------------------------------------------------------------ |
 | `ractor` (default) | Content varies by [Ractor](https://docs.ruby-lang.org/en/4.0/Ractor.html)                        |
 | `thread_group`     | Content varies by [ThreadGroup](https://docs.ruby-lang.org/en/4.0/ThreadGroup.html)              |
 | `thread`           | Content varies by [Thread](https://docs.ruby-lang.org/en/4.0/Thread.html)                        |
 | `fiber_storage`    | Content varies by [Fiber storage](https://docs.ruby-lang.org/en/4.0/Fiber.html#method-i-storage) |
 | `fiber`            | Content varies by [Fiber](https://docs.ruby-lang.org/en/4.0/Fiber.html)                          |

Fiber storage is typically inherited by a blocking fiber from the fiber creating it.

## Read Next

[README](../README.md#features) · [Variants](variants.md) · [Local scopes](scopes.md) · [Sharing Unshareable Data](sharing.md)
