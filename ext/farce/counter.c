#include "containers.h"

#include <limits.h>
#include <stdint.h>
#include <stdatomic.h>

_Static_assert(sizeof(long long) == sizeof(int64_t), "Counter requires a 64-bit long long");
_Static_assert(LLONG_MIN == INT64_MIN, "Counter requires a signed 64-bit long long");
_Static_assert(LLONG_MAX == INT64_MAX, "Counter requires a signed 64-bit long long");

#if ATOMIC_LLONG_LOCK_FREE == 2
#define CONTAINERS_COUNTER_LOCK_FREE 1
#else
#define CONTAINERS_COUNTER_LOCK_FREE 0
#endif

static VALUE cCounter;

typedef struct {
#if CONTAINERS_COUNTER_LOCK_FREE
    _Atomic long long value;
#else
    pthread_mutex_t lock;
    long long value;
#endif
    long long initial;
    bool initialized;
} counter_t;

/* On platforms with always-lock-free 64-bit atomics, counter operations only
 * linearize this numeric value. Relaxed ordering does not publish or
 * synchronize accesses to any other shared state. Platforms without that
 * guarantee use a mutex so 32-bit cross builds do not depend on libatomic. */

static void
counter_free(void *pointer)
{
#if !CONTAINERS_COUNTER_LOCK_FREE
    counter_t *counter = pointer;
    if (counter) pthread_mutex_destroy(&counter->lock);
#endif
    ruby_xfree(pointer);
}

static size_t
counter_memsize(const void *pointer)
{
    return pointer ? sizeof(counter_t) : 0;
}

static const rb_data_type_t counter_type = {
    .wrap_struct_name = "Ractor::Containers::Counter",
    .function = {
        .dfree = counter_free,
        .dsize = counter_memsize,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
counter_allocate(VALUE klass)
{
    counter_t *counter;
    VALUE object = TypedData_Make_Struct(klass, counter_t, &counter_type, counter);
#if CONTAINERS_COUNTER_LOCK_FREE
    atomic_init(&counter->value, 0);
#else
    pthread_mutex_init(&counter->lock, NULL);
    counter->value = 0;
#endif
    counter->initialized = false;
    return object;
}

static counter_t *
get_counter(VALUE self)
{
    counter_t *counter;
    TypedData_Get_Struct(self, counter_t, &counter_type, counter);
    if (!counter->initialized) rb_raise(rb_eRuntimeError, "uninitialized Counter");
    return counter;
}

static long long
counter_integer(VALUE value, const char *name)
{
    if (!RB_INTEGER_TYPE_P(value)) rb_raise(rb_eTypeError, "%s must be an Integer", name);
    return NUM2LL(value);
}

static VALUE
counter_initialize(int argc, VALUE *argv, VALUE self)
{
    counter_t *counter;

    rb_check_arity(argc, 0, 1);
    VALUE initial = argc == 0 ? INT2FIX(0) : argv[0];
    TypedData_Get_Struct(self, counter_t, &counter_type, counter);
    if (counter->initialized) rb_raise(rb_eRuntimeError, "Counter is already initialized");
    rb_check_frozen(self);

    long long value = counter_integer(initial, "initial value");
    rb_check_frozen(self);
#if CONTAINERS_COUNTER_LOCK_FREE
    atomic_store_explicit(&counter->value, value, memory_order_relaxed);
#else
    counter->value = value;
#endif
    counter->initial = value;
    counter->initialized = true;
    return containers_publish_native_reference_free(self);
}

static VALUE
counter_value(VALUE self)
{
    counter_t *counter = get_counter(self);
#if CONTAINERS_COUNTER_LOCK_FREE
    long long value = atomic_load_explicit(&counter->value, memory_order_relaxed);
#else
    pthread_mutex_lock(&counter->lock);
    long long value = counter->value;
    pthread_mutex_unlock(&counter->lock);
#endif
    return LL2NUM(value);
}

static VALUE
counter_initial(VALUE self)
{
    return LL2NUM(get_counter(self)->initial);
}

static VALUE
counter_initialize_copy(VALUE self, VALUE other)
{
    if (self == other) return self;
    rb_check_frozen(self);
    counter_t *copy;
    TypedData_Get_Struct(self, counter_t, &counter_type, copy);
    if (copy->initialized) rb_raise(rb_eRuntimeError, "copy is already initialized");
    counter_t *source = get_counter(other);
#if CONTAINERS_COUNTER_LOCK_FREE
    long long value = atomic_load_explicit(&source->value, memory_order_relaxed);
#else
    pthread_mutex_lock(&source->lock);
    long long value = source->value;
    pthread_mutex_unlock(&source->lock);
#endif
#if CONTAINERS_COUNTER_LOCK_FREE
    atomic_store_explicit(&copy->value, value, memory_order_relaxed);
#else
    copy->value = value;
#endif
    copy->initial = source->initial;
    copy->initialized = true;
    return containers_publish_native_reference_free(self);
}

static VALUE
counter_store(VALUE self, VALUE input)
{
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    long long value = counter_integer(input, "value");
#if CONTAINERS_COUNTER_LOCK_FREE
    atomic_store_explicit(&counter->value, value, memory_order_relaxed);
#else
    pthread_mutex_lock(&counter->lock);
    counter->value = value;
    pthread_mutex_unlock(&counter->lock);
#endif
    return input;
}

static VALUE
counter_swap(VALUE self, VALUE input)
{
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    long long replacement = counter_integer(input, "value");
#if CONTAINERS_COUNTER_LOCK_FREE
    long long current = atomic_load_explicit(&counter->value, memory_order_relaxed);

    for (;;) {
        VALUE result = LL2NUM(current);
        if (atomic_compare_exchange_weak_explicit(
                &counter->value,
                &current,
                replacement,
                memory_order_relaxed,
                memory_order_relaxed
            )) {
            return result;
        }
    }
#else
    pthread_mutex_lock(&counter->lock);
    long long current = counter->value;
    counter->value = replacement;
    pthread_mutex_unlock(&counter->lock);
    return LL2NUM(current);
#endif
}

static bool
counter_add_overflows(long long current, long long delta)
{
    return (delta > 0 && current > LLONG_MAX - delta) ||
        (delta < 0 && current < LLONG_MIN - delta);
}

static bool
counter_subtract_overflows(long long current, long long delta)
{
    return (delta > 0 && current < LLONG_MIN + delta) ||
        (delta < 0 && current > LLONG_MAX + delta);
}

static VALUE
counter_change(counter_t *counter, long long delta, bool subtract)
{
#if CONTAINERS_COUNTER_LOCK_FREE
    long long current = atomic_load_explicit(&counter->value, memory_order_relaxed);

    for (;;) {
        bool overflows = subtract
            ? counter_subtract_overflows(current, delta)
            : counter_add_overflows(current, delta);
        if (overflows) rb_raise(rb_eRangeError, "counter value is outside the signed 64-bit range");

        long long replacement = subtract ? current - delta : current + delta;
        VALUE result = LL2NUM(replacement);
        if (atomic_compare_exchange_weak_explicit(
                &counter->value,
                &current,
                replacement,
                memory_order_relaxed,
                memory_order_relaxed
            )) {
            return result;
        }
    }
#else
    pthread_mutex_lock(&counter->lock);
    long long current = counter->value;
    bool overflows = subtract
        ? counter_subtract_overflows(current, delta)
        : counter_add_overflows(current, delta);
    if (overflows) {
        pthread_mutex_unlock(&counter->lock);
        rb_raise(rb_eRangeError, "counter value is outside the signed 64-bit range");
    }

    long long replacement = subtract ? current - delta : current + delta;
    counter->value = replacement;
    pthread_mutex_unlock(&counter->lock);
    return LL2NUM(replacement);
#endif
}

static VALUE
counter_add(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 0, 1);
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    VALUE input = argc == 0 ? INT2FIX(1) : argv[0];
    long long delta = counter_integer(input, "delta");
    return counter_change(counter, delta, false);
}

static VALUE
counter_subtract(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 0, 1);
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    VALUE input = argc == 0 ? INT2FIX(1) : argv[0];
    long long delta = counter_integer(input, "delta");
    return counter_change(counter, delta, true);
}

static VALUE
counter_compare_and_set(VALUE self, VALUE expected_input, VALUE replacement_input)
{
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    long long expected = counter_integer(expected_input, "expected value");
    long long replacement = counter_integer(replacement_input, "replacement value");
#if CONTAINERS_COUNTER_LOCK_FREE
    bool exchanged = atomic_compare_exchange_strong_explicit(
        &counter->value,
        &expected,
        replacement,
        memory_order_relaxed,
        memory_order_relaxed
    );
#else
    pthread_mutex_lock(&counter->lock);
    bool exchanged = counter->value == expected;
    if (exchanged) counter->value = replacement;
    pthread_mutex_unlock(&counter->lock);
#endif
    return exchanged ? Qtrue : Qfalse;
}

/* The chainable operations are inherited directly by Farce::Counter. Keep
 * add/subtract as strict, value-returning primitives for internal callers. */
static VALUE
counter_increment(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 0, 1);
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    VALUE input = argc == 0 ? INT2FIX(1) : argv[0];
    if (!RB_INTEGER_TYPE_P(input)) {
        input = rb_Integer(input);
        rb_check_frozen(self);
    }
    long long delta = NUM2LL(input);
    (void)counter_change(counter, delta, false);
    return self;
}

static VALUE
counter_decrement(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 0, 1);
    counter_t *counter = get_counter(self);
    rb_check_frozen(self);
    VALUE input = argc == 0 ? INT2FIX(1) : argv[0];
    if (!RB_INTEGER_TYPE_P(input)) {
        input = rb_Integer(input);
        rb_check_frozen(self);
    }
    long long delta = NUM2LL(input);
    (void)counter_change(counter, delta, true);
    return self;
}

void
containers_init_counter(VALUE namespace)
{
    cCounter = rb_define_class_under(namespace, "Counter", rb_cNumeric);
    rb_define_alloc_func(cCounter, counter_allocate);
    rb_define_method(cCounter, "initialize", counter_initialize, -1);
    rb_define_private_method(cCounter, "initialize_copy", counter_initialize_copy, 1);
    rb_define_method(cCounter, "value", counter_value, 0);
    rb_define_alias(cCounter, "get", "value");
    rb_define_method(cCounter, "initial", counter_initial, 0);
    rb_define_method(cCounter, "store", counter_store, 1);
    rb_define_alias(cCounter, "value=", "store");
    rb_define_method(cCounter, "swap", counter_swap, 1);
    rb_define_method(cCounter, "add", counter_add, -1);
    rb_define_method(cCounter, "increment", counter_increment, -1);
    rb_define_method(cCounter, "subtract", counter_subtract, -1);
    rb_define_method(cCounter, "decrement", counter_decrement, -1);
    rb_define_method(cCounter, "compare_and_set", counter_compare_and_set, 2);
}
