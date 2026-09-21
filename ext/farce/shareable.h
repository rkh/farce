#ifndef FARCE_SHAREABLE_H
#define FARCE_SHAREABLE_H

#include "ruby.h"
#include "ruby/ractor.h"
#include "ruby/version.h"

/* CRuby 4.0 declares rb_obj_set_shareable in its public header, but some
 * installations do not export the symbol. The raw fallback is limited to the
 * audited 3.4/4.0 object layout. CRuby 4.1 must use the exported function so
 * global-GC and shared-reference bookkeeping run. */
static inline VALUE
farce_ruby_mark_shareable(VALUE object)
{
#if defined(FARCE_HAVE_EXPORTED_SHAREABLE_MARKER)
# if RUBY_API_VERSION_CODE < 40100
#  error "The exported shareable marker is enabled only for CRuby 4.1 or newer"
# endif
    return RB_OBJ_SET_SHAREABLE(object);
#elif defined(FARCE_USE_LEGACY_SHAREABLE_FLAG)
# if RUBY_API_VERSION_CODE < 30400 || RUBY_API_VERSION_CODE >= 40100
#  error "The legacy shareable flag is supported only on CRuby 3.4 and 4.0"
# endif
    RB_FL_SET_RAW(object, RUBY_FL_SHAREABLE);
    return object;
#else
# error "No supported CRuby shareable marker was configured"
#endif
}

#endif
