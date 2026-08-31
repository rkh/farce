#include "containers.h"
#include <ruby/atomic.h>
#include <ruby/fiber/scheduler.h>
#include <ruby/io.h>
#include <ruby/ractor.h>
#include <ruby/thread.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "dict.h"

#define PRIORITY_QUEUE_DEFAULT_CAPACITY 1024
#define PRIORITY_QUEUE_IDENTITY_INDEX_THRESHOLD 32

enum {
    PRIORITY_QUEUE_UNINITIALIZED = 0,
    PRIORITY_QUEUE_PUBLISHING = 1,
    PRIORITY_QUEUE_PUBLISHED = 2,
    PRIORITY_QUEUE_INITIALIZED = 3,
};

static inline bool
priority_queue_publication_busy(rb_atomic_t state)
{
    return state == PRIORITY_QUEUE_PUBLISHING ||
        state == PRIORITY_QUEUE_PUBLISHED;
}

typedef struct priority_queue_value priority_queue_value_t;
typedef struct priority_queue_bucket priority_queue_bucket_t;
typedef struct priority_queue_identity_index priority_queue_identity_index_t;

/* Build the snapshot through primitive String C APIs: retain the nominal
 * subclass, encoding, and instance variables, but neither copy singleton
 * methods nor invoke Ruby callbacks. */
static VALUE
priority_queue_snapshot_string(VALUE string)
{
    VALUE copy = rb_obj_alloc(rb_obj_class(string));
    VALUE instance_variables;
    long index;

    rb_str_replace(copy, string);
    instance_variables = rb_obj_instance_variables(string);
    for (index = 0; index < RARRAY_LEN(instance_variables); index++) {
        ID id = SYM2ID(RARRAY_AREF(instance_variables, index));
        rb_ivar_set(copy, id, rb_ivar_get(string, id));
    }
    rb_obj_freeze(copy);
    RB_GC_GUARD(instance_variables);
    return copy;
}

struct priority_queue_value {
    VALUE value;
    priority_queue_value_t *previous;
    priority_queue_value_t *next;
    priority_queue_value_t *identity_next;
};

typedef struct {
    VALUE identity;
    priority_queue_value_t *head;
    priority_queue_value_t *tail;
    bool occupied;
} priority_queue_identity_slot_t;

struct priority_queue_identity_index {
    priority_queue_identity_slot_t *slots;
    size_t capacity;
    size_t count;
};

/* dnode_t must remain the first member: Kazlib passes its address to the
 * configured node-free callback, where it is cast back to this structure. */
struct priority_queue_bucket {
    dnode_t node;
    VALUE priority;
    priority_queue_value_t *head;
    priority_queue_value_t *tail;
    priority_queue_identity_index_t *identity_index;
    size_t size;
};

static size_t
priority_queue_identity_hash(VALUE identity)
{
    uintptr_t bits = (uintptr_t)identity;
#if UINTPTR_MAX > UINT32_MAX
    bits ^= bits >> 33;
    bits *= UINT64_C(0xff51afd7ed558ccd);
    bits ^= bits >> 33;
    bits *= UINT64_C(0xc4ceb9fe1a85ec53);
    bits ^= bits >> 33;
#else
    bits ^= bits >> 16;
    bits *= UINT32_C(0x7feb352d);
    bits ^= bits >> 15;
    bits *= UINT32_C(0x846ca68b);
    bits ^= bits >> 16;
#endif
    return (size_t)bits;
}

static priority_queue_identity_index_t *
priority_queue_identity_index_allocate(size_t minimum_capacity)
{
    priority_queue_identity_index_t *index;
    size_t capacity = 64;

    while (capacity < minimum_capacity) {
        if (capacity > SIZE_MAX / 2) rb_memerror();
        capacity *= 2;
    }

    index = malloc(sizeof(priority_queue_identity_index_t));
    if (!index) rb_memerror();
    index->slots = calloc(capacity, sizeof(priority_queue_identity_slot_t));
    if (!index->slots) {
        free(index);
        rb_memerror();
    }
    index->capacity = capacity;
    index->count = 0;
    return index;
}

static void
priority_queue_identity_index_free(priority_queue_identity_index_t *index)
{
    if (!index) return;
    free(index->slots);
    free(index);
}

static priority_queue_identity_slot_t *
priority_queue_identity_index_lookup(priority_queue_identity_index_t *index, VALUE identity)
{
    size_t position;
    size_t mask;

    if (!index) return NULL;
    mask = index->capacity - 1;
    position = priority_queue_identity_hash(identity) & mask;
    while (index->slots[position].occupied) {
        if (index->slots[position].identity == identity) return &index->slots[position];
        position = (position + 1) & mask;
    }
    return NULL;
}

static priority_queue_identity_slot_t *
priority_queue_identity_index_insert_slot(
    priority_queue_identity_index_t *index,
    VALUE identity,
    priority_queue_value_t *head,
    priority_queue_value_t *tail
)
{
    size_t mask = index->capacity - 1;
    size_t position = priority_queue_identity_hash(identity) & mask;
    priority_queue_identity_slot_t *slot;

    while (index->slots[position].occupied) position = (position + 1) & mask;
    slot = &index->slots[position];
    slot->identity = identity;
    slot->head = head;
    slot->tail = tail;
    slot->occupied = true;
    index->count++;
    return slot;
}

static void
priority_queue_identity_index_resize(priority_queue_identity_index_t *index)
{
    priority_queue_identity_slot_t *old_slots = index->slots;
    size_t old_capacity = index->capacity;
    size_t new_capacity;
    size_t position;

    if (old_capacity > SIZE_MAX / 2) rb_memerror();
    new_capacity = old_capacity * 2;
    index->slots = calloc(new_capacity, sizeof(priority_queue_identity_slot_t));
    if (!index->slots) {
        index->slots = old_slots;
        rb_memerror();
    }
    index->capacity = new_capacity;
    index->count = 0;
    for (position = 0; position < old_capacity; position++) {
        priority_queue_identity_slot_t *slot = &old_slots[position];
        if (!slot->occupied) continue;
        priority_queue_identity_index_insert_slot(
            index,
            slot->identity,
            slot->head,
            slot->tail
        );
    }
    free(old_slots);
}

static void
priority_queue_identity_index_prepare_insert(
    priority_queue_identity_index_t *index,
    VALUE identity
)
{
    if (!index || priority_queue_identity_index_lookup(index, identity)) return;
    if (index->count + 1 > index->capacity / 2) {
        priority_queue_identity_index_resize(index);
    }
}

static void
priority_queue_identity_index_add(
    priority_queue_identity_index_t *index,
    priority_queue_value_t *entry
)
{
    priority_queue_identity_slot_t *slot;

    if (!index) return;
    entry->identity_next = NULL;
    slot = priority_queue_identity_index_lookup(index, entry->value);
    if (!slot) {
        priority_queue_identity_index_insert_slot(index, entry->value, entry, entry);
        return;
    }
    slot->tail->identity_next = entry;
    slot->tail = entry;
}

static void
priority_queue_identity_index_delete_slot(
    priority_queue_identity_index_t *index,
    priority_queue_identity_slot_t *deleted
)
{
    size_t mask = index->capacity - 1;
    size_t position = (size_t)(deleted - index->slots);

    memset(deleted, 0, sizeof(*deleted));
    index->count--;
    position = (position + 1) & mask;
    while (index->slots[position].occupied) {
        priority_queue_identity_slot_t moved = index->slots[position];
        memset(&index->slots[position], 0, sizeof(index->slots[position]));
        index->count--;
        priority_queue_identity_index_insert_slot(
            index,
            moved.identity,
            moved.head,
            moved.tail
        );
        position = (position + 1) & mask;
    }
}

static void
priority_queue_identity_index_remove(
    priority_queue_identity_index_t *index,
    priority_queue_value_t *entry
)
{
    priority_queue_identity_slot_t *slot;
    priority_queue_value_t *previous = NULL;

    if (!index) return;
    slot = priority_queue_identity_index_lookup(index, entry->value);
    if (!slot) rb_bug("priority queue identity index lost an entry");
    if (slot->head != entry) {
        for (previous = slot->head;
             previous && previous->identity_next != entry;
             previous = previous->identity_next) {
        }
        if (!previous) rb_bug("priority queue identity chain lost an entry");
    }

    if (previous) previous->identity_next = entry->identity_next;
    else slot->head = entry->identity_next;
    if (slot->tail == entry) slot->tail = previous;
    entry->identity_next = NULL;
    if (!slot->head) priority_queue_identity_index_delete_slot(index, slot);
}

static void
priority_queue_identity_index_build(priority_queue_bucket_t *bucket)
{
    priority_queue_identity_index_t *index;
    priority_queue_value_t *entry;
    size_t minimum_capacity;

    if (bucket->identity_index) return;
    if (bucket->size > SIZE_MAX / 2) rb_memerror();
    minimum_capacity = bucket->size * 2;
    index = priority_queue_identity_index_allocate(minimum_capacity);
    for (entry = bucket->head; entry; entry = entry->next) {
        priority_queue_identity_index_add(index, entry);
    }
    bucket->identity_index = index;
}

static void
priority_queue_identity_index_rebuild(priority_queue_bucket_t *bucket)
{
    priority_queue_identity_index_t *index = bucket->identity_index;
    priority_queue_value_t *entry;

    if (!index) return;
    memset(index->slots, 0, index->capacity * sizeof(priority_queue_identity_slot_t));
    index->count = 0;
    for (entry = bucket->head; entry; entry = entry->next) {
        entry->identity_next = NULL;
        priority_queue_identity_index_add(index, entry);
    }
}

static void
priority_queue_bucket_unlink(
    priority_queue_bucket_t *bucket,
    priority_queue_value_t *entry
)
{
    if (entry->previous) entry->previous->next = entry->next;
    else bucket->head = entry->next;
    if (entry->next) entry->next->previous = entry->previous;
    else bucket->tail = entry->previous;
    bucket->size--;
}

typedef struct priority_queue_lock_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    struct priority_queue_lock_waiter *next;
} priority_queue_lock_waiter_t;

typedef struct {
    dict_t tree;
    pthread_mutex_t lock;
    VALUE owner_fiber;
    VALUE owner_ruby_thread;
    priority_queue_lock_waiter_t *waiters;
    priority_queue_lock_waiter_t *last_waiter;
    /* Deliberately omitted from dmark: publication must remember its owner
     * without making that Fiber/Thread part of the shareable object graph. */
    VALUE publication_owner_fiber;
    VALUE publication_owner_ruby_thread;
    VALUE signal;
    size_t size;
    size_t capacity;
    bool bounded;
    bool closed;
    rb_atomic_t publication_state;
    bool mutex_initialized;
} priority_queue_t;

static VALUE cPriorityQueue;
static VALUE eClosedQueueError;
static VALUE eIsolationError;
static ID id_compare;
static ID id_broadcast;
static ID id_signal_ivar;

static void priority_queue_wait_for_publication(priority_queue_t *queue);

typedef struct {
    VALUE receiver;
    VALUE argument;
    bool equality;
    int comparison;
} priority_queue_callback_t;

static VALUE
priority_queue_callback_body(VALUE opaque)
{
    priority_queue_callback_t *callback = (priority_queue_callback_t *)opaque;
    if (callback->equality) return rb_equal(callback->receiver, callback->argument);

    VALUE result = rb_funcall(
        callback->receiver,
        id_compare,
        1,
        callback->argument
    );
    /* rb_cmpint can itself call Ruby `>`/`<` methods on a non-Integer result.
     * Keep the callback guard active through that conversion as well. */
    callback->comparison = rb_cmpint(
        result,
        callback->receiver,
        callback->argument
    );
    return Qnil;
}

static VALUE
priority_queue_call_ruby_callback(
    VALUE receiver,
    VALUE argument,
    bool equality,
    int *comparison
)
{
    priority_queue_callback_t callback = {
        .receiver = receiver,
        .argument = argument,
        .equality = equality,
        .comparison = 0,
    };

    VALUE result = priority_queue_callback_body((VALUE)&callback);
    if (comparison) *comparison = callback.comparison;
    return result;
}

static int
priority_queue_compare(const void *left_pointer, const void *right_pointer, void *context)
{
    VALUE left = (VALUE)left_pointer;
    VALUE right = (VALUE)right_pointer;
    int comparison;
    (void)context;

    if (FIXNUM_P(left) && FIXNUM_P(right)) {
        intptr_t left_value = (intptr_t)left;
        intptr_t right_value = (intptr_t)right;
        if (left_value < right_value) return -1;
        if (left_value > right_value) return 1;
        return 0;
    }
    if (CLASS_OF(left) == rb_cString && CLASS_OF(right) == rb_cString) {
        return rb_str_cmp(left, right);
    }
    if (CLASS_OF(left) == rb_cFloat && CLASS_OF(right) == rb_cFloat) {
        double left_value = RFLOAT_VALUE(left);
        double right_value = RFLOAT_VALUE(right);

        /* Float#<=> returns nil for NaN, which rb_cmpint turns into the
         * normal comparison ArgumentError. Keep that uncommon case on the
         * Ruby callback path rather than treating NaN as an equal priority. */
        if (!isnan(left_value) && !isnan(right_value)) {
            if (left_value < right_value) return -1;
            if (left_value > right_value) return 1;
            return 0;
        }
    }

    (void)priority_queue_call_ruby_callback(
        left,
        right,
        false,
        &comparison
    );
    return comparison;
}

static dnode_t *
priority_queue_allocate_tree_node(void *context)
{
    priority_queue_bucket_t *bucket = calloc(1, sizeof(priority_queue_bucket_t));
    (void)context;
    return bucket ? &bucket->node : NULL;
}

static void
priority_queue_free_tree_node(dnode_t *node, void *context)
{
    priority_queue_bucket_t *bucket = (priority_queue_bucket_t *)node;
    priority_queue_value_t *entry = bucket->head;
    (void)context;

    priority_queue_identity_index_free(bucket->identity_index);
    while (entry) {
        priority_queue_value_t *next = entry->next;
        free(entry);
        entry = next;
    }
    free(bucket);
}

static void
priority_queue_mark(void *pointer)
{
    priority_queue_t *queue = pointer;
    dnode_t *node;

    if (!queue) return;
    rb_gc_mark_movable(queue->owner_fiber);
    rb_gc_mark_movable(queue->owner_ruby_thread);
    rb_gc_mark_movable(queue->signal);
    for (node = dict_first(&queue->tree); node; node = dict_next(&queue->tree, node)) {
        priority_queue_bucket_t *bucket = (priority_queue_bucket_t *)node;
        priority_queue_value_t *entry;
        rb_gc_mark_movable(bucket->priority);
        for (entry = bucket->head; entry; entry = entry->next) {
            rb_gc_mark_movable(entry->value);
        }
    }
}

static void
priority_queue_compact(void *pointer)
{
    priority_queue_t *queue = pointer;
    dnode_t *node;

    if (!queue) return;
    queue->owner_fiber = rb_gc_location(queue->owner_fiber);
    queue->owner_ruby_thread = rb_gc_location(queue->owner_ruby_thread);
    /* The VM already roots the running publisher. dcompact only refreshes the
     * unmarked identity handles if that Fiber or Thread moved. */
    queue->publication_owner_fiber =
        rb_gc_location(queue->publication_owner_fiber);
    queue->publication_owner_ruby_thread =
        rb_gc_location(queue->publication_owner_ruby_thread);
    queue->signal = rb_gc_location(queue->signal);
    for (node = dict_first(&queue->tree); node; node = dict_next(&queue->tree, node)) {
        priority_queue_bucket_t *bucket = (priority_queue_bucket_t *)node;
        priority_queue_value_t *entry;
        bucket->priority = rb_gc_location(bucket->priority);
        node->dict_key = (const void *)bucket->priority;
        for (entry = bucket->head; entry; entry = entry->next) {
            entry->value = rb_gc_location(entry->value);
        }
        priority_queue_identity_index_rebuild(bucket);
    }
}

static void
priority_queue_free(void *pointer)
{
    priority_queue_t *queue = pointer;
    if (!queue) return;
    dict_free_nodes(&queue->tree);
    if (queue->mutex_initialized) pthread_mutex_destroy(&queue->lock);
    ruby_xfree(queue);
}

static size_t
priority_queue_memsize(const void *pointer)
{
    const priority_queue_t *queue = pointer;
    dnode_t *node;
    size_t size;

    if (!queue) return 0;
    size = sizeof(priority_queue_t)
        + (size_t)dict_count((dict_t *)&queue->tree) * sizeof(priority_queue_bucket_t)
        + queue->size * sizeof(priority_queue_value_t);
    for (node = dict_first((dict_t *)&queue->tree);
         node;
         node = dict_next((dict_t *)&queue->tree, node)) {
        priority_queue_bucket_t *bucket = (priority_queue_bucket_t *)node;
        priority_queue_identity_index_t *index = bucket->identity_index;
        if (!index) continue;
        size += sizeof(priority_queue_identity_index_t)
            + index->capacity * sizeof(priority_queue_identity_slot_t);
    }
    return size;
}

static const rb_data_type_t priority_queue_type = {
    .wrap_struct_name = "Farce::Internal::PriorityQueue",
    .function = {
        .dmark = priority_queue_mark,
        .dfree = priority_queue_free,
        .dsize = priority_queue_memsize,
        .dcompact = priority_queue_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
priority_queue_allocate(VALUE klass)
{
    priority_queue_t *queue;
    VALUE object = TypedData_Make_Struct(
        klass,
        priority_queue_t,
        &priority_queue_type,
        queue
    );
    int error;

    memset(queue, 0, sizeof(*queue));
    queue->owner_fiber = Qnil;
    queue->owner_ruby_thread = Qnil;
    queue->publication_owner_fiber = Qnil;
    queue->publication_owner_ruby_thread = Qnil;
    queue->signal = Qnil;
    RUBY_ATOMIC_SET(queue->publication_state, PRIORITY_QUEUE_UNINITIALIZED);
    dict_init(&queue->tree, priority_queue_compare);
    dict_set_allocator(
        &queue->tree,
        priority_queue_allocate_tree_node,
        priority_queue_free_tree_node,
        queue
    );
    error = pthread_mutex_init(&queue->lock, NULL);
    if (error) rb_syserr_fail(error, "pthread_mutex_init");
    queue->mutex_initialized = true;
    return object;
}

static priority_queue_t *
priority_queue_get_raw(VALUE self)
{
    priority_queue_t *queue;

    if (rb_typeddata_is_kind_of(self, &priority_queue_type)) {
        TypedData_Get_Struct(self, priority_queue_t, &priority_queue_type, queue);
        return queue;
    }
    rb_raise(rb_eTypeError, "wrong priority queue type");
}

static priority_queue_t *
priority_queue_get(VALUE self)
{
    priority_queue_t *queue = priority_queue_get_raw(self);

    rb_atomic_t state = RUBY_ATOMIC_LOAD(queue->publication_state);

    /* Primitive freezing can make a clean typed object Ractor-visible before
     * recursive publication returns. Always join an active publication, even
     * if an async exception is committing it, then recheck so a failed
     * traversal cannot leak a usable half-published queue. The steady-state
     * path is one atomic load and does not touch the physical mutex. */
    if (priority_queue_publication_busy(state)) {
        priority_queue_wait_for_publication(queue);
        state = RUBY_ATOMIC_LOAD(queue->publication_state);
    }
    if (state != PRIORITY_QUEUE_INITIALIZED) {
        rb_raise(rb_eRuntimeError, "uninitialized priority queue");
    }
    return queue;
}

static void
priority_queue_lock_set_fd_flags(int fd)
{
#ifdef _WIN32
    (void)fd;
#else
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
#endif
}

/* Called with queue->lock held. A logical unlock only needs to make one
 * waiter runnable. The selected waiter remains linked until ensure cleanup. */
static void
priority_queue_lock_notify_one_locked(priority_queue_t *queue)
{
    unsigned char byte = 1;
    priority_queue_lock_waiter_t *waiter;

    for (waiter = queue->waiters; waiter; waiter = waiter->next) {
        ssize_t result;
        if (waiter->notified) continue;
        do {
            result = write(waiter->write_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 ||
            (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            waiter->notified = true;
            return;
        }
    }
}

typedef struct {
    priority_queue_t *queue;
    priority_queue_lock_waiter_t waiter;
} priority_queue_lock_wait_context_t;

static bool
priority_queue_lock_wait_for_descriptor(int fd)
{
    VALUE io = rb_io_open_descriptor(
        rb_cIO,
        fd,
        FMODE_READABLE | FMODE_EXTERNAL,
        Qnil,
        Qnil,
        NULL
    );
    VALUE result = rb_io_wait(io, INT2NUM(RUBY_IO_READABLE), Qnil);
    RB_GC_GUARD(io);
    return RTEST(result);
}

static VALUE
priority_queue_lock_wait_body(VALUE opaque)
{
    priority_queue_lock_wait_context_t *context =
        (priority_queue_lock_wait_context_t *)opaque;
    bool awakened = priority_queue_lock_wait_for_descriptor(context->waiter.read_fd);
    return awakened ? Qtrue : Qfalse;
}

static VALUE
priority_queue_lock_wait_cleanup(VALUE opaque)
{
    priority_queue_lock_wait_context_t *context =
        (priority_queue_lock_wait_context_t *)opaque;
    priority_queue_lock_waiter_t *previous = NULL;
    priority_queue_lock_waiter_t **link;

    pthread_mutex_lock(&context->queue->lock);
    for (link = &context->queue->waiters; *link; link = &(*link)->next) {
        if (*link == &context->waiter) {
            *link = context->waiter.next;
            if (context->queue->last_waiter == &context->waiter) {
                context->queue->last_waiter = previous;
            }
            break;
        }
        previous = *link;
    }
    /* A notification only makes this waiter runnable; it does not reserve
     * ownership. Pass the baton whenever a notified waiter leaves while the
     * queue is still ownerless. This covers both interruption inside rb_io_wait
     * and cancellation after a normal wake but before the acquisition loop can
     * claim ownership, so later waiters cannot be stranded. */
    if (context->waiter.notified &&
        NIL_P(context->queue->owner_fiber) &&
        !priority_queue_publication_busy(
            RUBY_ATOMIC_LOAD(context->queue->publication_state)
        )) {
        priority_queue_lock_notify_one_locked(context->queue);
    }
    pthread_mutex_unlock(&context->queue->lock);
    close(context->waiter.read_fd);
    close(context->waiter.write_fd);
    return Qnil;
}

/* Called with queue->lock held and always returns with it released. */
static void
priority_queue_lock_wait_once(priority_queue_t *queue)
{
    int descriptors[2];
    priority_queue_lock_wait_context_t context;

    if (pipe(descriptors) != 0) {
        pthread_mutex_unlock(&queue->lock);
        rb_sys_fail("pipe");
    }
    priority_queue_lock_set_fd_flags(descriptors[0]);
    priority_queue_lock_set_fd_flags(descriptors[1]);

    context = (priority_queue_lock_wait_context_t){
        .queue = queue,
        .waiter = {
            .read_fd = descriptors[0],
            .write_fd = descriptors[1],
            .notified = false,
            .next = NULL,
        },
    };
    if (queue->last_waiter) queue->last_waiter->next = &context.waiter;
    else queue->waiters = &context.waiter;
    queue->last_waiter = &context.waiter;
    pthread_mutex_unlock(&queue->lock);
    (void)rb_ensure(
        priority_queue_lock_wait_body,
        (VALUE)&context,
        priority_queue_lock_wait_cleanup,
        (VALUE)&context
    );
}

static void
priority_queue_lock(priority_queue_t *queue, bool *acquired)
{
    VALUE current = rb_fiber_current();
    VALUE current_thread = rb_thread_current();
    VALUE scheduler = rb_fiber_scheduler_current();

    for (;;) {
        bool publication_busy;

        pthread_mutex_lock(&queue->lock);
        publication_busy = priority_queue_publication_busy(
            RUBY_ATOMIC_LOAD(queue->publication_state)
        );
        if (queue->owner_fiber == current ||
            (publication_busy && queue->publication_owner_fiber == current)) {
            pthread_mutex_unlock(&queue->lock);
            rb_raise(rb_eThreadError, "deadlock; recursive priority queue access");
        }
        if (NIL_P(queue->owner_fiber) && !publication_busy) {
            queue->owner_fiber = current;
            queue->owner_ruby_thread = current_thread;
            *acquired = true;
            pthread_mutex_unlock(&queue->lock);
            return;
        }
        if ((queue->owner_ruby_thread == current_thread ||
             (publication_busy &&
              queue->publication_owner_ruby_thread == current_thread)) &&
            NIL_P(scheduler)) {
            pthread_mutex_unlock(&queue->lock);
            rb_raise(
                rb_eThreadError,
                "deadlock; priority queue contention between unscheduled fibers"
            );
        }
        priority_queue_lock_wait_once(queue);
    }
}

static void
priority_queue_unlock(priority_queue_t *queue)
{
    rb_atomic_t state;

    pthread_mutex_lock(&queue->lock);
    state = RUBY_ATOMIC_LOAD(queue->publication_state);
    if (state == PRIORITY_QUEUE_PUBLISHED) {
        RUBY_ATOMIC_SET(queue->publication_state, PRIORITY_QUEUE_INITIALIZED);
    }
    else if (state == PRIORITY_QUEUE_PUBLISHING) {
        RUBY_ATOMIC_SET(queue->publication_state, PRIORITY_QUEUE_UNINITIALIZED);
    }
    queue->owner_fiber = Qnil;
    queue->owner_ruby_thread = Qnil;
    queue->publication_owner_fiber = Qnil;
    queue->publication_owner_ruby_thread = Qnil;
    priority_queue_lock_notify_one_locked(queue);
    pthread_mutex_unlock(&queue->lock);
}

typedef struct {
    priority_queue_t *queue;
    bool acquired;
} priority_queue_publication_wait_t;

static VALUE
priority_queue_publication_wait_body(VALUE opaque)
{
    priority_queue_publication_wait_t *wait =
        (priority_queue_publication_wait_t *)opaque;

    priority_queue_lock(wait->queue, &wait->acquired);
    return Qnil;
}

static VALUE
priority_queue_publication_wait_ensure(VALUE opaque)
{
    priority_queue_publication_wait_t *wait =
        (priority_queue_publication_wait_t *)opaque;

    if (wait->acquired) priority_queue_unlock(wait->queue);
    return Qnil;
}

static void
priority_queue_wait_for_publication(priority_queue_t *queue)
{
    priority_queue_publication_wait_t wait = {
        .queue = queue,
        .acquired = false,
    };

    /* The unmarked publication owner makes recursive callbacks fail with the
     * ordinary ThreadError, while other Ractors and scheduler-managed Fibers
     * park until the outer operation unlocks. */
    (void)rb_ensure(
        priority_queue_publication_wait_body,
        (VALUE)&wait,
        priority_queue_publication_wait_ensure,
        (VALUE)&wait
    );
}

typedef VALUE (*priority_queue_operation_t)(VALUE opaque);

typedef struct {
    priority_queue_t *queue;
    priority_queue_operation_t operation;
    VALUE argument;
    bool acquired;
} priority_queue_call_t;

static VALUE
priority_queue_call_body(VALUE opaque)
{
    priority_queue_call_t *call = (priority_queue_call_t *)opaque;
    priority_queue_lock(call->queue, &call->acquired);
    return call->operation(call->argument);
}

static VALUE
priority_queue_unlock_ensure(VALUE opaque)
{
    priority_queue_call_t *call = (priority_queue_call_t *)opaque;

    if (call->acquired) priority_queue_unlock(call->queue);
    return Qnil;
}

static VALUE
priority_queue_call(
    priority_queue_t *queue,
    priority_queue_operation_t operation,
    VALUE argument
)
{
    priority_queue_call_t call = {
        .queue = queue,
        .operation = operation,
        .argument = argument,
        .acquired = false,
    };

    return rb_ensure(
        priority_queue_call_body,
        (VALUE)&call,
        priority_queue_unlock_ensure,
        (VALUE)&call
    );
}

static void
priority_queue_check_shareable(VALUE value)
{
    if (!rb_ractor_shareable_p(value)) {
        rb_raise(eIsolationError, "value is not shareable: %" PRIsVALUE, rb_inspect(value));
    }
}

/* Notification is deliberately issued while the queue operation still owns
 * its lock and before the state commit. A woken waiter cannot inspect the queue
 * until the commit and unlock complete. Callers must finish every allocation
 * and user callback before this point, then use only no-fail C mutations.
 *
 * The new-bucket Kazlib insertion is the one conservative exception: Kazlib
 * repeats comparisons before linking the prepared node. If one raises, the
 * pending bucket ensure cleanup leaves the queue unchanged and the notification
 * is merely spurious; Kazlib never links a node before those comparisons end. */
static void
priority_queue_notify_before_commit(priority_queue_t *queue)
{
    if (!NIL_P(queue->signal)) rb_funcall(queue->signal, id_broadcast, 0);
}

RBIMPL_ATTR_NORETURN()
static void
priority_queue_raise_closed(void)
{
    rb_raise(eClosedQueueError, "queue is closed");
}

typedef struct {
    priority_queue_t *queue;
    VALUE self;
    VALUE signal;
    size_t capacity;
    bool bounded;
} priority_queue_initialize_t;

static void
priority_queue_check_initializable(VALUE self, priority_queue_t *queue)
{
    rb_atomic_t state = RUBY_ATOMIC_LOAD(queue->publication_state);

    if (state == PRIORITY_QUEUE_INITIALIZED) {
        rb_raise(rb_eRuntimeError, "priority queue is already initialized");
    }
    rb_check_frozen(self);

    /* Publication marks the object busy before primitive freeze. Reject the
     * narrow pre-freeze window here so a competing initializer cannot enter
     * user coercion callbacks while publication is already in progress. */
    if (RUBY_ATOMIC_LOAD(queue->publication_state) !=
        PRIORITY_QUEUE_UNINITIALIZED) {
        rb_raise(rb_eRuntimeError, "priority queue is already initialized");
    }
}

static VALUE
priority_queue_make_shareable(VALUE opaque)
{
    priority_queue_initialize_t *initialization =
        (priority_queue_initialize_t *)opaque;

    /* Primitive freeze bypasses an override on the receiver. The publication
     * gate and logical owner were installed before this point, so becoming
     * provisionally Ractor-visible cannot expose uninitialized native state. */
    rb_obj_freeze(initialization->self);
    return rb_ractor_make_shareable(initialization->self);
}

static VALUE
priority_queue_finish_publication(VALUE opaque)
{
    priority_queue_initialize_t *initialization =
        (priority_queue_initialize_t *)opaque;

    /* An async exception can arrive after rb_ractor_make_shareable has set the
     * shareable flag. In that case the native fields and Ruby ivars already
     * form a coherent queue, so publish initialized before propagating it. */
    pthread_mutex_lock(&initialization->queue->lock);
    if (rb_ractor_shareable_p(initialization->self)) {
        RUBY_ATOMIC_SET(
            initialization->queue->publication_state,
            PRIORITY_QUEUE_PUBLISHED
        );
    }
    pthread_mutex_unlock(&initialization->queue->lock);
    return Qnil;
}

static VALUE
priority_queue_publish_shareable(priority_queue_initialize_t *initialization)
{
    priority_queue_t *queue = initialization->queue;

    /* Install the gate before primitive freeze can make this typed object
     * Ractor-visible. Move the logical owner out of dmark before recursive
     * sharing, while retaining it for callback reentry/deadlock detection. */
    pthread_mutex_lock(&queue->lock);
    RUBY_ATOMIC_SET(queue->publication_state, PRIORITY_QUEUE_PUBLISHING);
    queue->publication_owner_fiber = queue->owner_fiber;
    queue->publication_owner_ruby_thread = queue->owner_ruby_thread;
    queue->owner_fiber = Qnil;
    queue->owner_ruby_thread = Qnil;
    pthread_mutex_unlock(&queue->lock);
    return rb_ensure(
        priority_queue_make_shareable,
        (VALUE)initialization,
        priority_queue_finish_publication,
        (VALUE)initialization
    );
}

static VALUE
priority_queue_initialize_commit(VALUE opaque)
{
    priority_queue_initialize_t *initialization =
        (priority_queue_initialize_t *)opaque;
    priority_queue_t *queue = initialization->queue;

    /* Capacity coercion and signal protocol checks above this commit can run
     * arbitrary Ruby. They may recursively initialize or freeze this object,
     * and two threads may finish parsing concurrently. The synchronized queue
     * serializes this authoritative recheck and the following no-fail field
     * assignments so a losing initializer cannot overwrite the winner. */
    if (RUBY_ATOMIC_LOAD(queue->publication_state) !=
        PRIORITY_QUEUE_UNINITIALIZED) {
        rb_raise(rb_eRuntimeError, "priority queue is already initialized");
    }
    rb_check_frozen(initialization->self);

    queue->bounded = initialization->bounded;
    queue->capacity = initialization->capacity;
    queue->signal = initialization->signal;
    /* The Ruby blocking layer reads @signal directly. Assign it as part of
     * the authoritative native commit so two callers racing initialize cannot
     * leave the Ruby wait path observing a losing initializer's Signal. */
    rb_ivar_set(initialization->self, id_signal_ivar, queue->signal);
    /* Publication installs its logical gate before primitive freezing and
     * keeps that whole transition under nested ensure cleanup. */
    return priority_queue_publish_shareable(initialization);
}

static VALUE
priority_queue_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE keywords = Qnil;
    VALUE keyword_values[2] = {Qundef, Qundef};
    ID keyword_ids[] = {rb_intern("capacity"), rb_intern("signal")};
    priority_queue_t *queue = priority_queue_get_raw(self);
    priority_queue_initialize_t initialization = {
        .queue = queue,
        .self = self,
        .signal = Qnil,
        .capacity = 0,
        .bounded = false,
    };
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) {
        rb_get_kwargs(keywords, keyword_ids, 0, 2, keyword_values);
    }
    priority_queue_check_initializable(self, queue);

    if (keyword_values[0] == Qnil) {
        initialization.bounded = false;
        initialization.capacity = 0;
    }
    else {
        VALUE capacity_value = keyword_values[0] == Qundef
            ? INT2FIX(PRIORITY_QUEUE_DEFAULT_CAPACITY)
            : rb_to_int(keyword_values[0]);
        long long capacity = NUM2LL(capacity_value);
        if (capacity <= 0) rb_raise(rb_eArgError, "capacity must be positive or nil");
        if ((unsigned long long)capacity > (unsigned long long)SIZE_MAX) {
            rb_raise(rb_eArgError, "capacity is too large");
        }
        initialization.bounded = true;
        initialization.capacity = (size_t)capacity;
    }

    if (keyword_values[1] != Qundef && !NIL_P(keyword_values[1])) {
        priority_queue_check_shareable(keyword_values[1]);
        if (!rb_respond_to(keyword_values[1], id_broadcast)) {
            rb_raise(rb_eTypeError, "signal must respond to #broadcast");
        }
        initialization.signal = keyword_values[1];
    }

    /* Capacity coercion and signal inspection can invoke arbitrary Ruby. A
     * sibling Fiber may pause there, then be resumed while another initializer
     * recursively freezes this receiver for Ractor publication. Reject that
     * resumed initializer before it can wait on the publisher's logical lock.
     * The commit retains its synchronized recheck for ordinary thread races. */
    priority_queue_check_initializable(self, queue);

    return priority_queue_call(
        queue,
        priority_queue_initialize_commit,
        (VALUE)&initialization
    );
}

static VALUE
priority_queue_initialize_copy(VALUE self, VALUE other)
{
    (void)self;
    (void)other;
    rb_raise(rb_eTypeError, "priority queues cannot be copied");
}

typedef struct {
    priority_queue_t *queue;
    VALUE self;
    VALUE priority;
    VALUE stored_priority;
    VALUE value;
    priority_queue_bucket_t *pending_bucket;
    priority_queue_value_t *pending_entry;
} priority_queue_push_t;

static VALUE
priority_queue_push_cleanup(VALUE opaque)
{
    priority_queue_push_t *push = (priority_queue_push_t *)opaque;
    if (push->pending_bucket) {
        priority_queue_free_tree_node(&push->pending_bucket->node, push->queue);
        push->pending_bucket = NULL;
    }
    if (push->pending_entry) {
        free(push->pending_entry);
        push->pending_entry = NULL;
    }
    return Qnil;
}

static VALUE
priority_queue_push_body(VALUE opaque)
{
    priority_queue_push_t *push = (priority_queue_push_t *)opaque;
    priority_queue_t *queue = push->queue;
    dnode_t *node;
    priority_queue_bucket_t *bucket;
    priority_queue_value_t *entry;

    if (queue->closed) priority_queue_raise_closed();
    if (queue->bounded && queue->size >= queue->capacity) return Qfalse;

    node = dict_lookup(&queue->tree, (const void *)push->priority);
    if (node) {
        bucket = (priority_queue_bucket_t *)node;
        priority_queue_identity_index_prepare_insert(bucket->identity_index, push->value);
        entry = malloc(sizeof(priority_queue_value_t));
        if (!entry) rb_memerror();
        entry->value = push->value;
        entry->previous = bucket->tail;
        entry->next = NULL;
        entry->identity_next = NULL;
        push->pending_entry = entry;
    }
    else {
        bucket = calloc(1, sizeof(priority_queue_bucket_t));
        entry = malloc(sizeof(priority_queue_value_t));
        if (!bucket || !entry) {
            free(bucket);
            free(entry);
            rb_memerror();
        }
        entry->value = push->value;
        entry->previous = NULL;
        entry->next = NULL;
        entry->identity_next = NULL;
        bucket->head = entry;
        bucket->tail = entry;
        bucket->size = 1;
        /* Own both allocations before copying a String priority: that copy can
         * raise, and the ensure handler must then release the partial bucket. */
        push->pending_bucket = bucket;
        if (RB_TYPE_P(push->priority, T_STRING)) {
            push->stored_priority = priority_queue_snapshot_string(push->priority);
        }
        else {
            push->stored_priority = push->priority;
        }
        bucket->priority = push->stored_priority;
        /* The bucket embeds its dnode and is recovered by address, so Kazlib's
         * auxiliary data slot is intentionally unused. Keeping it NULL also
         * means an unstable comparator's duplicate-insert fallback cannot
         * leave a pointer to the pending bucket after ensure frees it. */
        dnode_init(&bucket->node, NULL);
        bucket->node.dict_key = (const void *)bucket->priority;
        priority_queue_notify_before_commit(queue);
        bool inserted = dict_insert(
            &queue->tree,
            &bucket->node,
            bucket->node.dict_key
        );
        if (!inserted) {
            rb_raise(rb_eRuntimeError, "priority comparator changed during insertion");
        }
        push->pending_bucket = NULL;
        queue->size++;
        return Qtrue;
    }

    priority_queue_notify_before_commit(queue);
    if (bucket->tail) bucket->tail->next = entry;
    else bucket->head = entry;
    bucket->tail = entry;
    bucket->size++;
    priority_queue_identity_index_add(bucket->identity_index, entry);
    queue->size++;
    push->pending_entry = NULL;
    return Qtrue;
}

static VALUE
priority_queue_push_locked(VALUE opaque)
{
    return rb_ensure(
        priority_queue_push_body,
        opaque,
        priority_queue_push_cleanup,
        opaque
    );
}

static VALUE
priority_queue_push(VALUE self, VALUE priority, VALUE value)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_push_t push = {
        .queue = queue,
        .self = self,
        .priority = priority,
        .stored_priority = priority,
        .value = value,
        .pending_bucket = NULL,
        .pending_entry = NULL,
    };
    priority_queue_check_shareable(priority);
    priority_queue_check_shareable(value);
    return priority_queue_call(
        queue,
        priority_queue_push_locked,
        (VALUE)&push
    );
}

typedef enum {
    PRIORITY_QUEUE_POP,
    PRIORITY_QUEUE_PEEK,
    PRIORITY_QUEUE_PEEK_PRIORITY,
} priority_queue_read_kind_t;

typedef struct {
    priority_queue_t *queue;
    priority_queue_read_kind_t kind;
    VALUE result;
    bool empty;
} priority_queue_read_t;

static VALUE
priority_queue_read_body(VALUE opaque)
{
    priority_queue_read_t *read = (priority_queue_read_t *)opaque;
    priority_queue_t *queue = read->queue;
    dnode_t *node;
    priority_queue_bucket_t *bucket;
    priority_queue_value_t *entry;

    if (queue->closed) priority_queue_raise_closed();
    node = dict_first(&queue->tree);
    if (!node) {
        read->empty = true;
        return Qnil;
    }

    bucket = (priority_queue_bucket_t *)node;
    if (read->kind == PRIORITY_QUEUE_PEEK_PRIORITY) {
        read->result = (VALUE)dnode_getkey(node);
        return read->result;
    }

    read->result = bucket->head->value;
    if (read->kind == PRIORITY_QUEUE_PEEK) return read->result;

    entry = bucket->head;
    priority_queue_notify_before_commit(queue);
    priority_queue_identity_index_remove(bucket->identity_index, entry);
    priority_queue_bucket_unlink(bucket, entry);
    free(entry);
    queue->size--;
    if (bucket->size == 0) dict_delete_free(&queue->tree, node);
    return read->result;
}

static VALUE
priority_queue_read(VALUE self, priority_queue_read_kind_t kind)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_read_t read = {
        .queue = queue,
        .kind = kind,
        .result = Qnil,
        .empty = false,
    };
    priority_queue_call(
        queue,
        priority_queue_read_body,
        (VALUE)&read
    );
    if (read.empty) return rb_block_given_p() ? rb_yield_values(0) : Qnil;
    return read.result;
}

static VALUE
priority_queue_pop(VALUE self)
{
    return priority_queue_read(self, PRIORITY_QUEUE_POP);
}

static VALUE
priority_queue_peek(VALUE self)
{
    return priority_queue_read(self, PRIORITY_QUEUE_PEEK);
}

static VALUE
priority_queue_peek_priority(VALUE self)
{
    return priority_queue_read(self, PRIORITY_QUEUE_PEEK_PRIORITY);
}

typedef struct {
    priority_queue_t *queue;
    VALUE self;
    VALUE priority;
    VALUE value;
} priority_queue_delete_t;

static VALUE
priority_queue_delete_body(VALUE opaque)
{
    priority_queue_delete_t *deletion = (priority_queue_delete_t *)opaque;
    priority_queue_t *queue = deletion->queue;
    dnode_t *node;
    priority_queue_bucket_t *bucket;
    priority_queue_value_t *entry;

    if (queue->closed) priority_queue_raise_closed();
    node = dict_lookup(&queue->tree, (const void *)deletion->priority);
    if (!node) return Qfalse;
    bucket = (priority_queue_bucket_t *)node;

    for (entry = bucket->head; entry; entry = entry->next) {
        if (!RTEST(priority_queue_call_ruby_callback(
                entry->value,
                deletion->value,
                true,
                NULL
            ))) continue;
        priority_queue_notify_before_commit(queue);
        priority_queue_identity_index_remove(bucket->identity_index, entry);
        priority_queue_bucket_unlink(bucket, entry);
        free(entry);
        queue->size--;
        if (bucket->size == 0) dict_delete_free(&queue->tree, node);
        return Qtrue;
    }
    return Qfalse;
}

static VALUE
priority_queue_delete(VALUE self, VALUE priority, VALUE value)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_delete_t deletion = {
        .queue = queue,
        .self = self,
        .priority = priority,
        .value = value,
    };
    priority_queue_check_shareable(priority);
    priority_queue_check_shareable(value);
    return priority_queue_call(
        queue,
        priority_queue_delete_body,
        (VALUE)&deletion
    );
}

static VALUE
priority_queue_delete_identity_body(VALUE opaque)
{
    priority_queue_delete_t *deletion = (priority_queue_delete_t *)opaque;
    priority_queue_t *queue = deletion->queue;
    dnode_t *node;
    priority_queue_bucket_t *bucket;
    priority_queue_value_t *entry = NULL;

    if (queue->closed) priority_queue_raise_closed();
    node = dict_lookup(&queue->tree, (const void *)deletion->priority);
    if (!node) return Qfalse;
    bucket = (priority_queue_bucket_t *)node;

    if (!bucket->identity_index &&
        bucket->size >= PRIORITY_QUEUE_IDENTITY_INDEX_THRESHOLD) {
        priority_queue_identity_index_build(bucket);
    }
    if (bucket->identity_index) {
        priority_queue_identity_slot_t *slot = priority_queue_identity_index_lookup(
            bucket->identity_index,
            deletion->value
        );
        if (slot) entry = slot->head;
    }
    else {
        for (entry = bucket->head; entry; entry = entry->next) {
            if (entry->value == deletion->value) break;
        }
    }

    if (!entry) return Qfalse;
    priority_queue_notify_before_commit(queue);
    priority_queue_identity_index_remove(bucket->identity_index, entry);
    priority_queue_bucket_unlink(bucket, entry);
    free(entry);
    queue->size--;
    if (bucket->size == 0) dict_delete_free(&queue->tree, node);
    return Qtrue;
}

static VALUE
priority_queue_delete_identity(VALUE self, VALUE priority, VALUE value)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_delete_t deletion = {
        .queue = queue,
        .self = self,
        .priority = priority,
        .value = value,
    };
    priority_queue_check_shareable(priority);
    priority_queue_check_shareable(value);
    return priority_queue_call(
        queue,
        priority_queue_delete_identity_body,
        (VALUE)&deletion
    );
}

typedef struct {
    priority_queue_t *queue;
    VALUE self;
} priority_queue_self_operation_t;

static VALUE
priority_queue_size_body(VALUE opaque)
{
    priority_queue_self_operation_t *operation = (priority_queue_self_operation_t *)opaque;
    return SIZET2NUM(operation->queue->size);
}

static VALUE
priority_queue_size(VALUE self)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_self_operation_t operation = {.queue = queue, .self = self};
    return priority_queue_call(
        queue,
        priority_queue_size_body,
        (VALUE)&operation
    );
}

static VALUE
priority_queue_empty_body(VALUE opaque)
{
    priority_queue_self_operation_t *operation = (priority_queue_self_operation_t *)opaque;
    return operation->queue->size == 0 ? Qtrue : Qfalse;
}

static VALUE
priority_queue_empty(VALUE self)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_self_operation_t operation = {.queue = queue, .self = self};
    return priority_queue_call(
        queue,
        priority_queue_empty_body,
        (VALUE)&operation
    );
}

static VALUE
priority_queue_clear_body(VALUE opaque)
{
    priority_queue_self_operation_t *operation = (priority_queue_self_operation_t *)opaque;
    priority_queue_notify_before_commit(operation->queue);
    dict_free_nodes(&operation->queue->tree);
    operation->queue->size = 0;
    return operation->self;
}

static VALUE
priority_queue_clear(VALUE self)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_self_operation_t operation = {.queue = queue, .self = self};
    return priority_queue_call(
        queue,
        priority_queue_clear_body,
        (VALUE)&operation
    );
}

static VALUE
priority_queue_close_body(VALUE opaque)
{
    priority_queue_self_operation_t *operation = (priority_queue_self_operation_t *)opaque;
    priority_queue_notify_before_commit(operation->queue);
    operation->queue->closed = true;
    return operation->self;
}

static VALUE
priority_queue_close(VALUE self)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_self_operation_t operation = {.queue = queue, .self = self};
    return priority_queue_call(
        queue,
        priority_queue_close_body,
        (VALUE)&operation
    );
}

static VALUE
priority_queue_closed_body(VALUE opaque)
{
    priority_queue_self_operation_t *operation = (priority_queue_self_operation_t *)opaque;
    return operation->queue->closed ? Qtrue : Qfalse;
}

static VALUE
priority_queue_closed(VALUE self)
{
    priority_queue_t *queue = priority_queue_get(self);
    priority_queue_self_operation_t operation = {.queue = queue, .self = self};
    return priority_queue_call(
        queue,
        priority_queue_closed_body,
        (VALUE)&operation
    );
}

static VALUE
priority_queue_capacity(VALUE self)
{
    priority_queue_t *queue = priority_queue_get(self);
    return queue->bounded ? SIZET2NUM(queue->capacity) : Qnil;
}

static void
priority_queue_define_methods(VALUE klass)
{
    rb_define_private_method(klass, "initialize_storage", priority_queue_initialize, -1);
    rb_define_private_method(klass, "initialize_copy", priority_queue_initialize_copy, 1);
    rb_define_private_method(klass, "try_push", priority_queue_push, 2);
    rb_define_private_method(klass, "try_pop", priority_queue_pop, 0);
    rb_define_method(klass, "peek", priority_queue_peek, 0);
    rb_define_method(klass, "peek_priority", priority_queue_peek_priority, 0);
    rb_define_method(klass, "delete", priority_queue_delete, 2);
    rb_define_method(klass, "delete_identity", priority_queue_delete_identity, 2);
    rb_define_method(klass, "size", priority_queue_size, 0);
    rb_define_method(klass, "empty?", priority_queue_empty, 0);
    rb_define_method(klass, "clear", priority_queue_clear, 0);
    rb_define_method(klass, "close", priority_queue_close, 0);
    rb_define_method(klass, "closed?", priority_queue_closed, 0);
    rb_define_method(klass, "capacity", priority_queue_capacity, 0);
}

void
containers_init_priority_queue(VALUE namespace)
{
    ID id_ractor = rb_intern("Ractor");
    VALUE ractor;

    id_compare = rb_intern("<=>");
    id_broadcast = rb_intern("broadcast");
    id_signal_ivar = rb_intern("@signal");
    eClosedQueueError = rb_const_get(rb_cObject, rb_intern("ClosedQueueError"));
    ractor = rb_const_get(rb_cObject, id_ractor);
    eIsolationError = rb_const_get(ractor, rb_intern("IsolationError"));

    cPriorityQueue = rb_define_class_under(namespace, "PriorityQueue", rb_cObject);
    rb_define_alloc_func(cPriorityQueue, priority_queue_allocate);
    priority_queue_define_methods(cPriorityQueue);
}
