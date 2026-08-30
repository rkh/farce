<!--
# @title Gem: ractor-shim
-->

# Farce / [ractor-shim](https://github.com/eregon/ractor-shim)

> [!NOTE]
> This documentation is up to date for **Farce 0.1.0** and **ractor-shim 0.1.1**.

Both Farce and [ractor-shim](https://github.com/eregon/ractor-shim) provide shims for `Ractor` and `Ractor::Port` on platforms that don't fully support them. Farce namespaces these inside the `Farce` module, while ractor-shim installs these classes at top-level (where any shim-unaware code would automatically pick them up).

Farce ignores the shims provided by ractor-shim. Both gems can safely coexist in the same application.

## Similarities

* Both of them will use `Thread` and `Queue` under the hood if Ractors are not available.
* Both implement most of the public Ractor API.
* On Ruby implementations not supporting Ractors they both treat all objects as shareable. `Ractor.make_shareable` will not deep-freeze objects, and `Ractor.shareable?` will always return true.

## Implementation differences

The Ruby requirements for ractor-shim are much broader than for Farce, supporting Ruby 2.7 and later, while Farce requires Ruby 3.4 or newer. Farce is also significantly larger and more complex than ractor-shim. Its primary purpose isn't to provide a shim, but to provide tooling around Ractors and Fiber schedulers. So if all you need is a simple shim, ractor-shim is likely a better choice.

However, having these tools at its disposal allows Farce to provide a more complete and in some cases more performant solution.

### Things Farce implements that ractor-shim does not

Farce supports ractors having multiple threads. The following snippet will work fine with Farce (after `include Farce`), but will raise an exception with ractor-shim on Ruby 2.x, TruffleRuby, and JRuby:

```ruby
Ractor.new do
  Thread.new { p Ractor.current }.join
end.join
```

The `Ractor.store_if_absent` method provided by ractor-shim may not be thread-safe.

`Ractor.shareable_proc` and `Ractor.shareable_lambda` are not properly implemented in ractor-shim. They do not accept a `self` option and will not rebind the passed block. In addition, `shareable_lambda` does not actually produce lambdas on Ruby 3.

### Things Farce implements more efficiently

* `Ractor.select` on ractor-shim uses busy waiting if native Ractors are not available. Farce uses better synchronization mechanisms to properly avoid busy waiting. Moreover, ractor-shim wraps the select logic in a global mutex, meaning only one `Ractor.select` can be active at any time. Farce does not have this limitation.
* The `Ractor::Port` shim provided by ractor-shim always creates a new Ractor for each port. Farce only does so if absolutely necessary (on Ruby 3.4, if sending unshareable objects over a non-default port).

On Ruby 3.4, the following code will create one Ractor if using Farce, but 6 Ractors if using ractor-shim:

```ruby
ractor = Ractor.new do
  counter = 0
  while port = receive
    counter += 1
    port.send(counter)
  end
end

5.times do
  port = Ractor::Port.new
  ractor.send(port)
  puts "Count is: #{port.receive}"
ensure
  port.close
end
```
