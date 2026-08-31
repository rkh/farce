# Native containers

Farce's single CRuby extension defines its internal coordinated containers,
including `Atom`, `Counter`, `Exchanger`, `Flag`, `Lock`, `Map`, `Queue`,
`Signal`, `Vector`, `LocalTreeMap`, `TreeMap`, `ShareableTreeMap`, and
`PriorityQueue`. CRuby 4.1+ also gets native `WeakMap`, `WeakKeyMap`, and
`WeakValueMap` implementations.

The tree maps use Farce's MIT-licensed clean-room red-black tree. String keys
are normalized like `-key`, producing frozen, globally deduplicated keys that
can be recovered with `getkey`. Other keys must already be Ractor-shareable.
`LocalTreeMap` is unsynchronized, while `TreeMap` is synchronized; both accept
arbitrary values and follow ordinary Ruby freeze semantics. `ShareableTreeMap`
is synchronized, requires shareable values, and is itself frozen and
Ractor-shareable.

`PriorityQueue` uses the vendored Kazlib dictionary implementation with one
FIFO bucket per priority. Exact deletion visits only the requested priority's
bucket. Kazlib's copyright and license remain in `dict.c` and `dict.h`.

The extension is built and loaded only on CRuby. Other engines use their Ruby
or JVM implementations and never compile this directory.
