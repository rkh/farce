#include "containers.h"

static VALUE eIsolationError;

RBIMPL_ATTR_NORETURN()
static void
raise_unshareable(VALUE value)
{
    rb_raise(eIsolationError, "value is not shareable: %" PRIsVALUE, rb_inspect(value));
}

void
containers_check_shareable(VALUE value)
{
    if (!rb_ractor_shareable_p(value)) raise_unshareable(value);
}

bool
containers_strict_bool(VALUE value, const char *name)
{
    if (value == Qtrue) return true;
    if (value == Qfalse) return false;
    rb_raise(rb_eArgError, "%s must be true or false", name);
}

void
containers_finish_initialization(VALUE self)
{
    rb_obj_freeze(self);
    rb_ractor_make_shareable(self);
}

void
containers_raise_key_error(VALUE receiver, VALUE key)
{
    VALUE message = rb_sprintf("key not found: %" PRIsVALUE, rb_inspect(key));
    VALUE keywords = rb_hash_new();
    rb_hash_aset(keywords, ID2SYM(rb_intern("receiver")), receiver);
    rb_hash_aset(keywords, ID2SYM(rb_intern("key")), key);
    VALUE arguments[] = {message, keywords};
    VALUE exception = rb_class_new_instance_kw(2, arguments, rb_eKeyError, RB_PASS_KEYWORDS);
    rb_exc_raise(exception);
}

RUBY_FUNC_EXPORTED void
Init_containers(void)
{
    rb_ext_ractor_safe(true);
    VALUE mFarce    = rb_const_get(rb_cObject, rb_intern("Farce"));
    VALUE mInternal = rb_const_get(mFarce, rb_intern("Internal"));
    eIsolationError = rb_const_get(rb_cRactor, rb_intern("IsolationError"));
    containers_init_atom(mInternal);
    containers_init_counter(mInternal);
    containers_init_exchanger(mInternal);
    containers_init_flag(mInternal);
    containers_init_lock(mInternal);
    containers_init_map(mInternal);
    containers_init_priority_queue(mInternal);
    containers_init_queue(mInternal);
    containers_init_signal(mInternal);
    containers_init_unshared_signal(mInternal);
    containers_init_unshareable(mInternal);
    containers_init_vector(mInternal);
    containers_init_weak_maps(mInternal);
    containers_init_tree_maps(mInternal);
}
