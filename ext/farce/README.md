# Native extension

Farce's CRuby extension defines its internal coordinated containers, including `Atom`, `Counter`, `Exchanger`, `Flag`, `Lock`, `Map`, `Queue`, `Signal`, `Vector`, `UnsafeTreeMap`, `TreeMap`, `ShareableTreeMap`, and `PriorityQueue`. CRuby 4.1+ also gets native `WeakAtom`, `WeakMap`, `WeakKeyMap`, and `WeakValueMap` implementations.

On platforms with epoll or kqueue, the same extension also provides Farce's native fiber scheduler. The scheduler class is initialized lazily so selecting the Ruby `select` implementation does not load or expose the native scheduler.

The tree maps use a red-black tree. String keys are normalized like `-key`, producing frozen, globally deduplicated keys that
can be recovered with `getkey`. Other keys must already be Ractor-shareable. `UnsafeTreeMap` is unsynchronized, while `TreeMap` is synchronized. Both accept arbitrary values and follow ordinary Ruby freeze semantics. `ShareableTreeMap` is synchronized, requires shareable values, and is itself frozen and Ractor-shareable.

`PriorityQueue` uses the vendored Kazlib dictionary implementation with one FIFO bucket per priority (this is the same implementation used by the rbtree gem). Exact deletion visits only the requested priority's bucket. Kazlib's copyright and license remain in `dict.c` and `dict.h`.

`Queue` uses a bounded or growing FIFO ring. Its `try_push` and `try_pop` entry points share the checked operation bodies with `push` and `pop`, while avoiding keyword allocation and clock reads for polling. Vacated slots are cleared, and the GC hooks visit only the live portion of the ring.

The extension is built and loaded only on CRuby. Other engines use their Ruby or JVM implementations and never compile this directory.

This extension is intentionally kept separate from the `rebind` extension, as the other extension is tightly bound to CRuby internals and may have to be adjusted for each new Ruby version.


## AI Usage

OpenAI's Astra has been used to explore and fix bugs in this extensions, primarily for implementing Windows support, as well as for performance and high contention testing. All generated code has been reviewed extensively if it ended up being used in the final implementation.
