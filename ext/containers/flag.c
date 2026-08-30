#include "containers.h"

#include <stdatomic.h>

_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "Flag requires always-lock-free boolean atomics");

static VALUE cFlag;

typedef struct {
    atomic_bool value;
    bool initialized;
} flag_t;

/* Flag operations only linearize this boolean value. Relaxed ordering does
 * not publish or synchronize accesses to any other shared state. */

static void
flag_free(void *pointer)
{
    ruby_xfree(pointer);
}

static size_t
flag_memsize(const void *pointer)
{
    return pointer ? sizeof(flag_t) : 0;
}

static const rb_data_type_t flag_type = {
    .wrap_struct_name = "Ractor::Containers::Flag",
    .function = {
        .dfree = flag_free,
        .dsize = flag_memsize,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
flag_boolean(bool value)
{
    return value ? Qtrue : Qfalse;
}

static flag_t *
get_flag(VALUE self)
{
    flag_t *flag;
    TypedData_Get_Struct(self, flag_t, &flag_type, flag);
    if (!flag->initialized) rb_raise(rb_eRuntimeError, "uninitialized Flag");
    return flag;
}

static VALUE
flag_allocate(VALUE klass)
{
    flag_t *flag;
    VALUE object = TypedData_Make_Struct(klass, flag_t, &flag_type, flag);
    atomic_init(&flag->value, false);
    flag->initialized = false;
    if (!atomic_is_lock_free(&flag->value)) {
        rb_raise(rb_eNotImpError, "boolean atomic flags are not lock-free on this platform");
    }
    return object;
}

static VALUE
flag_initialize(int argc, VALUE *argv, VALUE self)
{
    flag_t *flag;

    rb_check_arity(argc, 0, 1);
    VALUE initial = argc == 0 ? Qfalse : argv[0];
    TypedData_Get_Struct(self, flag_t, &flag_type, flag);
    if (flag->initialized) rb_raise(rb_eRuntimeError, "Flag is already initialized");
    rb_check_frozen(self);

    bool value = containers_strict_bool(initial, "initial value");
    atomic_store_explicit(&flag->value, value, memory_order_relaxed);
    flag->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static VALUE
flag_value(VALUE self)
{
    flag_t *flag = get_flag(self);
    return flag_boolean(atomic_load_explicit(&flag->value, memory_order_relaxed));
}

static VALUE
flag_set(VALUE self)
{
    flag_t *flag = get_flag(self);
    atomic_store_explicit(&flag->value, true, memory_order_relaxed);
    return Qtrue;
}

static VALUE
flag_store(VALUE self, VALUE input)
{
    flag_t *flag = get_flag(self);
    bool value = containers_strict_bool(input, "value");
    atomic_store_explicit(&flag->value, value, memory_order_relaxed);
    return input;
}

static VALUE
flag_swap(VALUE self, VALUE input)
{
    flag_t *flag = get_flag(self);
    bool replacement = containers_strict_bool(input, "value");
    bool previous = atomic_exchange_explicit(
        &flag->value,
        replacement,
        memory_order_relaxed
    );
    return flag_boolean(previous);
}

static VALUE
flag_compare_and_set(VALUE self, VALUE expected_input, VALUE replacement_input)
{
    flag_t *flag = get_flag(self);
    bool expected = containers_strict_bool(expected_input, "expected value");
    bool replacement = containers_strict_bool(replacement_input, "replacement value");
    bool exchanged = atomic_compare_exchange_strong_explicit(
        &flag->value,
        &expected,
        replacement,
        memory_order_relaxed,
        memory_order_relaxed
    );
    return flag_boolean(exchanged);
}

static VALUE
flag_toggle(VALUE self)
{
    flag_t *flag = get_flag(self);
    bool current = atomic_load_explicit(&flag->value, memory_order_relaxed);

    for (;;) {
        bool replacement = !current;
        if (atomic_compare_exchange_weak_explicit(
                &flag->value,
                &current,
                replacement,
                memory_order_relaxed,
                memory_order_relaxed
            )) {
            return flag_boolean(replacement);
        }
    }
}

void
containers_init_flag(VALUE namespace)
{
    cFlag = rb_define_class_under(namespace, "Flag", rb_cObject);
    rb_define_alloc_func(cFlag, flag_allocate);
    rb_define_method(cFlag, "initialize", flag_initialize, -1);
    rb_define_method(cFlag, "value", flag_value, 0);
    rb_define_alias(cFlag, "get", "value");
    rb_define_method(cFlag, "set", flag_set, 0);
    rb_define_method(cFlag, "store", flag_store, 1);
    rb_define_alias(cFlag, "value=", "store");
    rb_define_method(cFlag, "swap", flag_swap, 1);
    rb_define_method(cFlag, "compare_and_set", flag_compare_and_set, 2);
    rb_define_method(cFlag, "toggle", flag_toggle, 0);
}
