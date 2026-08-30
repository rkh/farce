# Patched RBTree

This directory contains a patched version of [Ruby/RBTree](https://github.com/mame/rbtree).

The following changes have been made to the original RBTree library:

* The extension is marked as Ractor-safe (not the instances, just the extension, so function calls can run in parallel). Important! It is not actually thread-safe. RBTree instances should have synchronization applied externally.
* RBTree and MultiRBTree are defined under the `Farce::Internal` namespace and thus aren't easily accessible from outside the Farce gem. It also means the extension can be loaded in the same Ruby environment as the original RBTree gem, without conflicts.
* It generates a no-op Makefile on JRuby. Ruby code will have to check if the binaries exist / the constants are defined. This is all handled by `farce/engine`.

The modifications are clearly marked and can be found in the `Init_rbtree` function in `rbtree.c`.

## License

MIT License. Copyright (c) 2002-2013 OZAWA Takuma.

dict.c and dict.h are modified copies that are originally in Kazlib
1.20 written by Kaz Kylheku. Its license is similar to the MIT
license. See dict.c and dict.h for the details. The web page of Kazlib
is at http://www.kylheku.com/~kaz/kazlib.html.
