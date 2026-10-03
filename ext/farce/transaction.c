#include "transaction.h"
#include <stdlib.h>
#include "ruby/thread.h"

static VALUE cTransactionEntry;

static void
transaction_entry_mark(void *pointer)
{
    farce_transaction_entry_t *entry = pointer;
    rb_gc_mark_movable(entry->source);
    rb_gc_mark_movable(entry->working);
}

static void
transaction_entry_compact(void *pointer)
{
    farce_transaction_entry_t *entry = pointer;
    entry->source = rb_gc_location(entry->source);
    entry->working = rb_gc_location(entry->working);
}

static size_t
transaction_entry_memsize(const void *pointer)
{
    return pointer ? sizeof(farce_transaction_entry_t) : 0;
}

static const rb_data_type_t transaction_entry_type = {
    .wrap_struct_name = "Farce::Internal::NativeTransactionEntry",
    .function = {
        .dmark = transaction_entry_mark,
        .dfree = RUBY_TYPED_DEFAULT_FREE,
        .dsize = transaction_entry_memsize,
        .dcompact = transaction_entry_compact,
    },
};

VALUE
farce_transaction_entry_new(
    VALUE source, VALUE working, void *source_data, void *working_data,
    pthread_mutex_t *lock, const farce_transaction_ops_t *ops,
    farce_transaction_entry_t **entry
)
{
    VALUE object = TypedData_Make_Struct(
        cTransactionEntry, farce_transaction_entry_t, &transaction_entry_type, *entry
    );
    **entry = (farce_transaction_entry_t){
        .source = source, .working = working,
        .source_data = source_data, .working_data = working_data,
        .lock = lock, .ops = ops,
    };
    return object;
}

static farce_transaction_entry_t *
get_transaction_entry(VALUE self)
{
    farce_transaction_entry_t *entry;
    TypedData_Get_Struct(self, farce_transaction_entry_t, &transaction_entry_type, entry);
    if (entry->finished) rb_raise(rb_eRuntimeError, "transaction entry is closed");
    return entry;
}

static VALUE
transaction_entry_working(VALUE self)
{
    return get_transaction_entry(self)->working;
}

static VALUE
transaction_entry_write(VALUE self)
{
    get_transaction_entry(self)->dirty = true;
    return Qnil;
}

static int
transaction_entry_order(const void *left, const void *right)
{
    uintptr_t a = (uintptr_t)(*(farce_transaction_entry_t *const *)left)->lock;
    uintptr_t b = (uintptr_t)(*(farce_transaction_entry_t *const *)right)->lock;
    return (a > b) - (a < b);
}

static VALUE
transaction_commit(VALUE namespace, VALUE entries, VALUE guards)
{
    Check_Type(entries, T_ARRAY);
    Check_Type(guards, T_ARRAY);
    /* Type-check guards before acquiring participant locks. */
    for (long i = 0; i < RARRAY_LEN(guards); i++) {
        if (farce_transaction_flag_set(RARRAY_AREF(guards, i))) return Qfalse;
    }
    long count = RARRAY_LEN(entries);
    VALUE buffer = 0;
    farce_transaction_entry_t **ordered = ALLOCV_N(farce_transaction_entry_t *, buffer, count);
    for (long i = 0; i < count; i++) {
        ordered[i] = get_transaction_entry(RARRAY_AREF(entries, i));
    }
    qsort(ordered, (size_t)count, sizeof(*ordered), transaction_entry_order);
    for (long i = 1; i < count; i++) {
        if (ordered[i - 1]->lock == ordered[i]->lock) {
            ALLOCV_END(buffer);
            rb_raise(rb_eArgError, "duplicate transaction participant");
        }
    }

    /* Try rather than wait while holding a peer's native mutex. In particular,
     * no GC safepoint, Ruby callback, or interrupt check is allowed below. */
    long locked = 0;
    bool valid = true;
    for (; locked < count; locked++) {
        if (pthread_mutex_trylock(ordered[locked]->lock) != 0) {
            valid = false;
            break;
        }
    }
    if (valid) {
        for (long i = 0; i < count; i++) {
            farce_transaction_entry_t *entry = ordered[i];
            if ((entry->dirty && RB_OBJ_FROZEN(entry->source)) || !entry->ops->valid(entry)) {
                valid = false;
                break;
            }
        }
    }
    if (valid) {
        for (long i = 0; i < RARRAY_LEN(guards); i++) {
            if (farce_transaction_flag_set(RARRAY_AREF(guards, i))) {
                valid = false;
                break;
            }
        }
    }
    if (valid) {
        for (long i = 0; i < count; i++) {
            if (ordered[i]->dirty) ordered[i]->ops->apply(ordered[i]);
        }
        for (long i = 0; i < count; i++) {
            if (ordered[i]->dirty) ordered[i]->ops->notify(ordered[i]);
        }
    }
    while (locked > 0) pthread_mutex_unlock(ordered[--locked]->lock);
    for (long i = 0; i < count; i++) ordered[i]->finished = true;
    ALLOCV_END(buffer);
    RB_GC_GUARD(entries);
    return valid ? Qtrue : Qfalse;
}

/* The ensure frame owns both logical native reservations and the portable
 * lock context. No Ruby callback runs while several state mutexes are held. */
typedef struct {
    VALUE entries;
    VALUE guards;
    VALUE context;
    VALUE transaction;
    VALUE fiber;
    VALUE thread;
    VALUE cleanup_error;
    farce_transaction_entry_t **ordered;
    long count;
    bool acquired;
} transaction_reservation_t;

typedef struct {
    VALUE receiver;
    ID method;
} transaction_call_t;

static VALUE
transaction_call_protected(VALUE opaque)
{
    transaction_call_t *call = (void *)opaque;
    return rb_funcall(call->receiver, call->method, 0);
}

/* Cleanup must finish after foreign publication, including when a return
 * TracePoint raises. Cleanup operations are idempotent and retried before
 * propagating the original error. Async cancellation is masked by run. */
static VALUE
transaction_cleanup_call(transaction_reservation_t *reservation, ID method)
{
    transaction_call_t call = {.receiver = reservation->context, .method = method};
    for (;;) {
        int state = 0;
        VALUE result = rb_protect(transaction_call_protected, (VALUE)&call, &state);
        if (!state) return result;
        if (NIL_P(reservation->cleanup_error)) reservation->cleanup_error = rb_errinfo();
        rb_set_errinfo(Qnil);
    }
}

static VALUE
transaction_schedule(VALUE ignored)
{
    rb_thread_schedule();
    return Qnil;
}

static long
transaction_try_lock_all(transaction_reservation_t *reservation)
{
    long locked = 0;
    for (; locked < reservation->count; locked++) {
        if (pthread_mutex_trylock(reservation->ordered[locked]->lock) != 0) break;
    }
    return locked;
}

static void
transaction_unlock_all(transaction_reservation_t *reservation, long locked)
{
    while (locked > 0) pthread_mutex_unlock(reservation->ordered[--locked]->lock);
}

static VALUE
transaction_reservation_body(VALUE opaque)
{
    transaction_reservation_t *reservation = (void *)opaque;
    if (!RTEST(rb_funcall(reservation->context, rb_intern("acquire?"), 0))) return Qfalse;
    long locked = transaction_try_lock_all(reservation);
    bool valid = locked == reservation->count;
    if (valid) {
        for (long i = 0; i < reservation->count; i++) {
            farce_transaction_entry_t *entry = reservation->ordered[i];
            if ((entry->dirty && RB_OBJ_FROZEN(entry->source)) || !entry->ops->valid(entry)) {
                valid = false;
                break;
            }
        }
    }
    if (valid) {
        for (long i = 0; i < RARRAY_LEN(reservation->guards); i++) {
            if (farce_transaction_flag_set(RARRAY_AREF(reservation->guards, i))) {
                valid = false;
                break;
            }
        }
    }
    if (valid) {
        for (long i = 0; i < reservation->count; i++) {
            farce_transaction_entry_t *entry = reservation->ordered[i];
            entry->ops->reserve(entry, reservation->fiber, reservation->thread);
            entry->reserved = true;
        }
        reservation->acquired = true;
    }
    transaction_unlock_all(reservation, locked);
    if (!valid) return Qfalse;
    rb_funcall(reservation->context, rb_intern("publish_external"), 0);
    return Qtrue;
}

static VALUE
transaction_reservation_ensure(VALUE opaque)
{
    transaction_reservation_t *reservation = (void *)opaque;
    VALUE original_error = rb_errinfo();
    bool committed = RTEST(transaction_cleanup_call(reservation, rb_intern("committed?")));
    if (!committed) transaction_cleanup_call(reservation, rb_intern("restore"));
    if (reservation->acquired) {
        long locked;
        while ((locked = transaction_try_lock_all(reservation)) != reservation->count) {
            transaction_unlock_all(reservation, locked);
            int state = 0;
            (void)rb_protect(transaction_schedule, Qnil, &state);
            if (state) {
                if (NIL_P(reservation->cleanup_error)) reservation->cleanup_error = rb_errinfo();
                rb_set_errinfo(Qnil);
            }
        }
        if (committed) {
            for (long i = 0; i < reservation->count; i++) {
                farce_transaction_entry_t *entry = reservation->ordered[i];
                if (entry->dirty) entry->ops->apply(entry);
            }
            for (long i = 0; i < reservation->count; i++) {
                farce_transaction_entry_t *entry = reservation->ordered[i];
                if (entry->dirty) entry->ops->notify(entry);
            }
        }
        for (long i = 0; i < reservation->count; i++) {
            farce_transaction_entry_t *entry = reservation->ordered[i];
            entry->ops->release(entry);
            entry->reserved = false;
        }
        transaction_unlock_all(reservation, locked);
    }
    for (long i = 0; i < reservation->count; i++) reservation->ordered[i]->finished = true;
    if (!NIL_P(reservation->transaction)) {
        rb_ivar_set(reservation->transaction, rb_intern("@state"),
            ID2SYM(rb_intern(committed ? "committed" : "failed")));
    }
    transaction_cleanup_call(reservation, rb_intern("finish"));
    rb_set_errinfo(original_error);
    if (NIL_P(original_error) && !NIL_P(reservation->cleanup_error)) {
        rb_exc_raise(reservation->cleanup_error);
    }
    RB_GC_GUARD(original_error);
    return Qnil;
}

static VALUE
transaction_reserve(VALUE namespace, VALUE entries, VALUE guards, VALUE context)
{
    Check_Type(entries, T_ARRAY);
    Check_Type(guards, T_ARRAY);
    for (long i = 0; i < RARRAY_LEN(guards); i++) {
        (void)farce_transaction_flag_set(RARRAY_AREF(guards, i));
    }
    long count = RARRAY_LEN(entries);
    VALUE buffer = 0;
    farce_transaction_entry_t **ordered = ALLOCV_N(farce_transaction_entry_t *, buffer, count);
    for (long i = 0; i < count; i++) {
        ordered[i] = get_transaction_entry(RARRAY_AREF(entries, i));
        if (!ordered[i]->ops->reserve || !ordered[i]->ops->release) {
            ALLOCV_END(buffer);
            rb_raise(rb_eTypeError, "participant does not support commit reservations");
        }
    }
    qsort(ordered, (size_t)count, sizeof(*ordered), transaction_entry_order);
    for (long i = 1; i < count; i++) {
        if (ordered[i - 1]->lock == ordered[i]->lock) {
            ALLOCV_END(buffer);
            rb_raise(rb_eArgError, "duplicate transaction participant");
        }
    }
    transaction_reservation_t reservation = {
        .entries = entries, .guards = guards, .context = context,
        .transaction = rb_ivar_get(context, rb_intern("@transaction")),
        .fiber = rb_fiber_current(), .thread = rb_thread_current(),
        .cleanup_error = Qnil, .ordered = ordered, .count = count,
    };
    VALUE result = rb_ensure(transaction_reservation_body, (VALUE)&reservation,
                             transaction_reservation_ensure, (VALUE)&reservation);
    ALLOCV_END(buffer);
    RB_GC_GUARD(entries);
    RB_GC_GUARD(guards);
    RB_GC_GUARD(context);
    return result;
}

void
containers_init_transaction(VALUE namespace)
{
    cTransactionEntry = rb_define_class_under(namespace, "NativeTransactionEntry", rb_cObject);
    rb_undef_alloc_func(cTransactionEntry);
    rb_define_method(cTransactionEntry, "working", transaction_entry_working, 0);
    rb_define_method(cTransactionEntry, "write!", transaction_entry_write, 0);
    rb_define_singleton_method(namespace, "commit_transaction", transaction_commit, 2);
    rb_define_singleton_method(namespace, "reserve_transaction", transaction_reserve, 3);
}
