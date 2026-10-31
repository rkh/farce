#ifndef FARCE_WEAK_REFERENCES_H
#define FARCE_WEAK_REFERENCES_H

#include "ruby.h"
#include <stdbool.h>

#ifdef RC_HAVE_NATIVE_WEAK_REFERENCES
/* These symbols are exported, but their declarations remain internal. The
 * callback and liveness function gained the same opaque GC context together. */
void rb_gc_declare_weak_references(VALUE object);

#ifdef FARCE_WEAK_REFERENCES_HAVE_OBJSPACE
bool rb_gc_handle_weak_references_alive_p(void *objspace, VALUE object);
# define FARCE_WEAK_REFERENCES_CALLBACK(name) name(void *pointer, void *objspace)
# define FARCE_WEAK_REFERENCE_ALIVE_P(object) rb_gc_handle_weak_references_alive_p(objspace, object)
#else
bool rb_gc_handle_weak_references_alive_p(VALUE object);
# define FARCE_WEAK_REFERENCES_CALLBACK(name) name(void *pointer)
# define FARCE_WEAK_REFERENCE_ALIVE_P(object) rb_gc_handle_weak_references_alive_p(object)
#endif
#endif

#endif
