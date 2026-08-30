# Ractor-safe containers

Farce-internal extension adding the following classes:

On CRuby 3.4+:
* `Farce::Internal::Atom`
* `Farce::Internal::Map`
* `Farce::Internal::Queue`

On CRuby 4.1+:
* `Farce::Internal::WeakMap`
* `Farce::Internal::WeakKeyMap`
* `Farce::Internal::WeakValueMap`

Generates a no-op Makefile on alternative Ruby implementations.
