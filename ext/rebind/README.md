# Block rebinding

A small extension for block rebinding on CRuby.

Rebinding rather than wrapping procs is necessary for some use cases, such as retaining Ractor-shareability.
It also produces significantly faster and smaller procs than wrapping or casting to an unbound method and rebinding.

It does however rely on MRI internals, as there are no public APIs for this, so it needs to be verified for each new Ruby version. This is in part why it is kept as a separate extension.

On Ruby implementations other than MRI it generates a dummy Makefile, so it still "compiles".

## AI Usage

Anthropic's Claude AI has been used to explore the underlying data structures, identify edge cases, and helped write the patch. All generated code has been reviewed extensively if it ended up being used in the final implementation.
