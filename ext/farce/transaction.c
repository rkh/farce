#include "transaction.h"
#include <stdlib.h>

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

void
containers_init_transaction(VALUE namespace)
{
    cTransactionEntry = rb_define_class_under(namespace, "NativeTransactionEntry", rb_cObject);
    rb_undef_alloc_func(cTransactionEntry);
    rb_define_method(cTransactionEntry, "working", transaction_entry_working, 0);
    rb_define_method(cTransactionEntry, "write!", transaction_entry_write, 0);
    rb_define_singleton_method(namespace, "commit_transaction", transaction_commit, 2);
}
