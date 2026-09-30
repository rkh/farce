#include "containers.h"

#include <stdatomic.h>

#if ATOMIC_BOOL_LOCK_FREE == 2
#define CONTAINERS_FLAG_LOCK_FREE 1
#else
#define CONTAINERS_FLAG_LOCK_FREE 0
#endif

static VALUE cFlag;

typedef struct {
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_bool value;
#else
    pthread_mutex_t lock;
    bool value;
#endif
    bool initialized;
} flag_t;

/* On platforms with always-lock-free boolean atomics, flag operations only
 * linearize this boolean value. Relaxed ordering does not publish or
 * synchronize accesses to any other shared state. Platforms without that
 * guarantee use a mutex. */

static void
flag_free(void *pointer)
{
#if !CONTAINERS_FLAG_LOCK_FREE
    flag_t *flag = pointer;
    if (flag) pthread_mutex_destroy(&flag->lock);
#endif
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
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_init(&flag->value, false);
#else
    pthread_mutex_init(&flag->lock, NULL);
    flag->value = false;
#endif
    flag->initialized = false;
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
    rb_check_frozen(self);
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_store_explicit(&flag->value, value, memory_order_relaxed);
#else
    flag->value = value;
#endif
    flag->initialized = true;
    return containers_publish_native_reference_free(self);
}

static VALUE
flag_value(VALUE self)
{
    flag_t *flag = get_flag(self);
#if CONTAINERS_FLAG_LOCK_FREE
    bool value = atomic_load_explicit(&flag->value, memory_order_relaxed);
#else
    pthread_mutex_lock(&flag->lock);
    bool value = flag->value;
    pthread_mutex_unlock(&flag->lock);
#endif
    return flag_boolean(value);
}

static VALUE
flag_initialize_copy(VALUE self, VALUE other)
{
    if (self == other) return self;
    rb_check_frozen(self);
    flag_t *copy;
    TypedData_Get_Struct(self, flag_t, &flag_type, copy);
    if (copy->initialized) rb_raise(rb_eRuntimeError, "copy is already initialized");
    bool value = RTEST(flag_value(other));
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_store_explicit(&copy->value, value, memory_order_relaxed);
#else
    copy->value = value;
#endif
    copy->initialized = true;
    return containers_publish_native_reference_free(self);
}

static VALUE
flag_set(VALUE self)
{
    flag_t *flag = get_flag(self);
    containers_check_typed_frozen(self);
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_store_explicit(&flag->value, true, memory_order_relaxed);
#else
    pthread_mutex_lock(&flag->lock);
    flag->value = true;
    pthread_mutex_unlock(&flag->lock);
#endif
    return Qtrue;
}

static VALUE
flag_unset(VALUE self)
{
    flag_t *flag = get_flag(self);
    containers_check_typed_frozen(self);
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_store_explicit(&flag->value, false, memory_order_relaxed);
#else
    pthread_mutex_lock(&flag->lock);
    flag->value = false;
    pthread_mutex_unlock(&flag->lock);
#endif
    return Qfalse;
}

static VALUE
flag_store(VALUE self, VALUE input)
{
    flag_t *flag = get_flag(self);
    containers_check_typed_frozen(self);
    bool value = containers_strict_bool(input, "value");
#if CONTAINERS_FLAG_LOCK_FREE
    atomic_store_explicit(&flag->value, value, memory_order_relaxed);
#else
    pthread_mutex_lock(&flag->lock);
    flag->value = value;
    pthread_mutex_unlock(&flag->lock);
#endif
    return input;
}

static VALUE
flag_swap(VALUE self, VALUE input)
{
    flag_t *flag = get_flag(self);
    containers_check_typed_frozen(self);
    bool replacement = containers_strict_bool(input, "value");
#if CONTAINERS_FLAG_LOCK_FREE
    bool previous = atomic_exchange_explicit(
        &flag->value,
        replacement,
        memory_order_relaxed
    );
#else
    pthread_mutex_lock(&flag->lock);
    bool previous = flag->value;
    flag->value = replacement;
    pthread_mutex_unlock(&flag->lock);
#endif
    return flag_boolean(previous);
}

static VALUE
flag_compare_and_set(VALUE self, VALUE expected_input, VALUE replacement_input)
{
    flag_t *flag = get_flag(self);
    containers_check_typed_frozen(self);
    bool expected = containers_strict_bool(expected_input, "expected value");
    bool replacement = containers_strict_bool(replacement_input, "replacement value");
#if CONTAINERS_FLAG_LOCK_FREE
    bool exchanged = atomic_compare_exchange_strong_explicit(
        &flag->value,
        &expected,
        replacement,
        memory_order_relaxed,
        memory_order_relaxed
    );
#else
    pthread_mutex_lock(&flag->lock);
    bool exchanged = flag->value == expected;
    if (exchanged) flag->value = replacement;
    pthread_mutex_unlock(&flag->lock);
#endif
    return flag_boolean(exchanged);
}

static VALUE
flag_toggle(VALUE self)
{
    flag_t *flag = get_flag(self);
    containers_check_typed_frozen(self);
#if CONTAINERS_FLAG_LOCK_FREE
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
#else
    pthread_mutex_lock(&flag->lock);
    bool value = flag->value = !flag->value;
    pthread_mutex_unlock(&flag->lock);
    return flag_boolean(value);
#endif
}

void
containers_init_flag(VALUE namespace)
{
    cFlag = rb_define_class_under(namespace, "Flag", rb_cObject);
    rb_define_alloc_func(cFlag, flag_allocate);
    rb_define_method(cFlag, "initialize", flag_initialize, -1);
    rb_define_private_method(cFlag, "initialize_copy", flag_initialize_copy, 1);
    rb_define_method(cFlag, "value", flag_value, 0);
    rb_define_alias(cFlag, "get", "value");
    rb_define_method(cFlag, "set", flag_set, 0);
    rb_define_method(cFlag, "unset", flag_unset, 0);
    rb_define_method(cFlag, "store", flag_store, 1);
    rb_define_alias(cFlag, "value=", "store");
    rb_define_method(cFlag, "swap", flag_swap, 1);
    rb_define_method(cFlag, "compare_and_set", flag_compare_and_set, 2);
    rb_define_method(cFlag, "toggle", flag_toggle, 0);
}
