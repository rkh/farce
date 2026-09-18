#include "containers.h"

#ifdef RC_HAVE_NATIVE_WEAK_REFERENCES

#include "ruby/fiber/scheduler.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define WEAK_MAP_INITIAL_CAPACITY 16

/* These functions are exported by Rubies with the probed typed-data weak
 * reference callback, but their declarations intentionally remain internal. */
void rb_gc_declare_weak_references(VALUE object);
bool rb_gc_handle_weak_references_alive_p(VALUE object);

static VALUE cWeakKeyMap;
static VALUE cWeakValueMap;
static VALUE cWeakMap;

typedef enum {
    WEAK_MAP_EMPTY = 0,
    WEAK_MAP_OCCUPIED = 1,
    WEAK_MAP_TOMBSTONE = 2
} weak_map_slot_state_t;

typedef struct {
    VALUE key;
    VALUE value;
    st_index_t hash;
    weak_map_slot_state_t state;
} weak_map_slot_t;

typedef struct weak_map_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    struct weak_map_waiter *next;
} weak_map_waiter_t;

typedef struct {
    pthread_mutex_t lock;
    weak_map_slot_t *slots;
    size_t capacity;
    size_t size;
    size_t tombstones;
    uint64_t generation;
    weak_map_waiter_t *waiters;
    bool compare_keys_by_identity;
    bool compare_values_by_identity;
    bool weak_keys;
    bool weak_values;
    bool comparing;
    VALUE comparing_owner;
    pthread_t comparing_thread;
    bool updating;
    VALUE updating_fiber;
    VALUE updating_thread;
    bool initialized;
} weak_map_t;

typedef struct {
    bool finite;
    double deadline;
} weak_map_timeout_t;

typedef struct {
    VALUE fiber;
    VALUE thread;
    VALUE scheduler;
    pthread_t native_thread;
} weak_map_execution_context_t;

static double
weak_map_monotonic_now(void)
{
    struct timespec now;
#ifdef CLOCK_MONOTONIC
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
        return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
    }
#endif
    struct timeval fallback;
    gettimeofday(&fallback, NULL);
    return (double)fallback.tv_sec + (double)fallback.tv_usec / 1000000.0;
}

static weak_map_timeout_t
weak_map_parse_timeout(VALUE timeout)
{
    weak_map_timeout_t parsed = {.finite = false, .deadline = 0};
    if (NIL_P(timeout)) return parsed;
    double seconds = NUM2DBL(timeout);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    parsed.finite = true;
    parsed.deadline = weak_map_monotonic_now() + seconds;
    return parsed;
}

static void
weak_map_set_fd_flags(int fd)
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

static void
weak_map_waiter_initialize(weak_map_waiter_t *waiter)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) rb_sys_fail("pipe");
    waiter->read_fd = descriptors[0];
    waiter->write_fd = descriptors[1];
    waiter->notified = false;
    waiter->next = NULL;
    weak_map_set_fd_flags(waiter->read_fd);
    weak_map_set_fd_flags(waiter->write_fd);
}

static void
weak_map_notify_waiters_locked(weak_map_t *map)
{
    unsigned char byte = 1;
    map->generation++;
    for (weak_map_waiter_t *waiter = map->waiters; waiter; waiter = waiter->next) {
        if (waiter->notified) continue;
        ssize_t result;
        do {
            result = write(waiter->write_fd, &byte, 1);
        } while (result < 0 && errno == EINTR);
        if (result == 1 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            waiter->notified = true;
        }
    }
}

static void
weak_map_mark(void *pointer)
{
    weak_map_t *map = pointer;
    rb_gc_mark_movable(map->comparing_owner);
    rb_gc_mark_movable(map->updating_fiber);
    rb_gc_mark_movable(map->updating_thread);
    if (!map->slots) return;

    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state != WEAK_MAP_OCCUPIED) continue;
        if (!map->weak_keys) rb_gc_mark_movable(slot->key);
        if (!map->weak_values) rb_gc_mark_movable(slot->value);
    }
}

static void
weak_map_compact(void *pointer)
{
    weak_map_t *map = pointer;
    map->comparing_owner = rb_gc_location(map->comparing_owner);
    map->updating_fiber = rb_gc_location(map->updating_fiber);
    map->updating_thread = rb_gc_location(map->updating_thread);
    if (!map->slots) return;

    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state != WEAK_MAP_OCCUPIED) continue;
        slot->key = rb_gc_location(slot->key);
        slot->value = rb_gc_location(slot->value);
    }
}

/* The VM invokes this after marking while mutators are stopped. Taking the map
 * mutex here could deadlock if GC stopped a mutator at a safepoint while it
 * owned the mutex, so cleanup deliberately runs lock-free. */
static void
weak_map_handle_weak_references(void *pointer)
{
    weak_map_t *map = pointer;
    if (!map->slots) return;
    bool changed = false;

    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        if (slot->state != WEAK_MAP_OCCUPIED) continue;

        bool key_alive = !map->weak_keys || rb_gc_handle_weak_references_alive_p(slot->key);
        bool value_alive = !map->weak_values || rb_gc_handle_weak_references_alive_p(slot->value);
        if (key_alive && value_alive) continue;

        slot->key = Qnil;
        slot->value = Qnil;
        slot->state = WEAK_MAP_TOMBSTONE;
        map->size--;
        map->tombstones++;
        changed = true;
    }
    if (changed) weak_map_notify_waiters_locked(map);
}

static void
weak_map_free(void *pointer)
{
    weak_map_t *map = pointer;
    pthread_mutex_destroy(&map->lock);
    free(map->slots);
    ruby_xfree(map);
}

static size_t
weak_map_memsize(const void *pointer)
{
    const weak_map_t *map = pointer;
    return map ? sizeof(weak_map_t) + map->capacity * sizeof(weak_map_slot_t) : 0;
}

static const rb_data_type_t weak_map_type = {
    .wrap_struct_name = "Ractor::Containers::WeakMap",
    .function = {
        .dmark = weak_map_mark,
        .dfree = weak_map_free,
        .dsize = weak_map_memsize,
        .dcompact = weak_map_compact,
        .handle_weak_references = weak_map_handle_weak_references,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static weak_map_slot_t *
weak_map_allocate_slots(size_t capacity)
{
    weak_map_slot_t *slots = calloc(capacity, sizeof(weak_map_slot_t));
    if (!slots) rb_memerror();
    return slots;
}

static weak_map_slot_t *
weak_map_allocate_slots_locked(weak_map_t *map, size_t capacity)
{
    weak_map_slot_t *slots = calloc(capacity, sizeof(weak_map_slot_t));
    if (!slots) {
        pthread_mutex_unlock(&map->lock);
        rb_memerror();
    }
    return slots;
}

static VALUE
weak_map_allocate(VALUE klass)
{
    weak_map_t *map;
    VALUE object = TypedData_Make_Struct(klass, weak_map_t, &weak_map_type, map);
    pthread_mutex_init(&map->lock, NULL);
    map->slots = NULL;
    map->capacity = 0;
    map->size = 0;
    map->tombstones = 0;
    map->generation = 0;
    map->waiters = NULL;
    map->compare_keys_by_identity = false;
    map->compare_values_by_identity = false;
    map->weak_keys = klass == cWeakKeyMap || klass == cWeakMap;
    map->weak_values = klass == cWeakValueMap || klass == cWeakMap;
    map->comparing = false;
    map->comparing_owner = Qnil;
    map->updating = false;
    map->updating_fiber = Qnil;
    map->updating_thread = Qnil;
    map->initialized = false;
    return object;
}

static weak_map_t *
get_weak_map(VALUE self)
{
    weak_map_t *map;
    TypedData_Get_Struct(self, weak_map_t, &weak_map_type, map);
    if (!map->initialized) rb_raise(rb_eRuntimeError, "uninitialized weak map");
    return map;
}

typedef struct {
    weak_map_t *map;
    weak_map_waiter_t *waiter;
    weak_map_timeout_t *timeout;
    bool registered;
} weak_map_wait_context_t;

static VALUE
weak_map_wait_body(VALUE opaque)
{
    weak_map_wait_context_t *context = (weak_map_wait_context_t *)opaque;
    VALUE wait_timeout = Qnil;
    if (context->timeout->finite) {
        double remaining = context->timeout->deadline - weak_map_monotonic_now();
        if (remaining <= 0) return Qfalse;
        wait_timeout = DBL2NUM(remaining);
    }
    return containers_wait_for_readable(context->waiter->read_fd, wait_timeout) ? Qtrue : Qfalse;
}

static VALUE
weak_map_wait_cleanup(VALUE opaque)
{
    weak_map_wait_context_t *context = (weak_map_wait_context_t *)opaque;
    if (context->registered) {
        pthread_mutex_lock(&context->map->lock);
        weak_map_waiter_t **cursor = &context->map->waiters;
        while (*cursor && *cursor != context->waiter) cursor = &(*cursor)->next;
        if (*cursor) *cursor = context->waiter->next;
        pthread_mutex_unlock(&context->map->lock);
        context->registered = false;
    }
    close(context->waiter->read_fd);
    close(context->waiter->write_fd);
    return Qnil;
}

static bool
weak_map_wait_once(weak_map_t *map, uint64_t generation, weak_map_timeout_t *timeout)
{
    weak_map_waiter_t waiter;
    weak_map_waiter_initialize(&waiter);

    pthread_mutex_lock(&map->lock);
    if (map->generation != generation) {
        pthread_mutex_unlock(&map->lock);
        close(waiter.read_fd);
        close(waiter.write_fd);
        return true;
    }
    waiter.next = map->waiters;
    map->waiters = &waiter;
    pthread_mutex_unlock(&map->lock);

    weak_map_wait_context_t context = {
        .map = map,
        .waiter = &waiter,
        .timeout = timeout,
        .registered = true,
    };
    return RTEST(rb_ensure(
        weak_map_wait_body,
        (VALUE)&context,
        weak_map_wait_cleanup,
        (VALUE)&context
    ));
}

static void
weak_map_lock_state(weak_map_t *map, weak_map_execution_context_t *execution)
{
    weak_map_timeout_t timeout = {.finite = false, .deadline = 0};
    execution->fiber = rb_fiber_current();
    execution->thread = rb_thread_current();
    execution->scheduler = rb_fiber_scheduler_current();
    execution->native_thread = pthread_self();

    for (;;) {
        pthread_mutex_lock(&map->lock);
        if (!map->comparing) return;

        if (map->comparing_owner == execution->fiber) {
            pthread_mutex_unlock(&map->lock);
            rb_raise(rb_eThreadError, "recursive weak-map access from key equality");
        }
        if (pthread_equal(map->comparing_thread, execution->native_thread) &&
            NIL_P(execution->scheduler)) {
            pthread_mutex_unlock(&map->lock);
            rb_raise(
                rb_eThreadError,
                "deadlock; weak-map key equality is owned by another unscheduled fiber"
            );
        }

        uint64_t generation = map->generation;
        pthread_mutex_unlock(&map->lock);
        (void)weak_map_wait_once(map, generation, &timeout);
    }
}

static void
weak_map_check_update_wait_locked(
    weak_map_t *map,
    const weak_map_execution_context_t *execution
)
{
    if (map->updating_fiber == execution->fiber) {
        pthread_mutex_unlock(&map->lock);
        rb_raise(rb_eThreadError, "deadlock; recursive weak-map access during an update");
    }
    if (map->updating_thread == execution->thread && NIL_P(execution->scheduler)) {
        pthread_mutex_unlock(&map->lock);
        rb_raise(
            rb_eThreadError,
            "deadlock; weak-map update is owned by another unscheduled fiber"
        );
    }
}

static void
weak_map_begin_update_locked(
    weak_map_t *map,
    const weak_map_execution_context_t *execution
)
{
    map->updating = true;
    map->updating_fiber = execution->fiber;
    map->updating_thread = execution->thread;
}

static void
weak_map_finish_update_locked(weak_map_t *map)
{
    map->updating = false;
    map->updating_fiber = Qnil;
    map->updating_thread = Qnil;
}

static bool
weak_map_lock_for_update_with_timeout(
    weak_map_t *map,
    weak_map_timeout_t *timeout,
    weak_map_execution_context_t *execution
)
{
    for (;;) {
        weak_map_lock_state(map, execution);
        if (!map->updating) return true;
        weak_map_check_update_wait_locked(map, execution);
        uint64_t generation = map->generation;
        pthread_mutex_unlock(&map->lock);
        if (!weak_map_wait_once(map, generation, timeout)) return false;
    }
}

static VALUE
weak_map_timeout_result(void)
{
    return rb_block_given_p() ? rb_yield_values(0) : Qnil;
}

static void
weak_map_lock_for_update(weak_map_t *map, weak_map_execution_context_t *execution)
{
    weak_map_timeout_t timeout = {.finite = false, .deadline = 0};

    for (;;) {
        weak_map_lock_state(map, execution);
        if (!map->updating) return;
        weak_map_check_update_wait_locked(map, execution);
        uint64_t generation = map->generation;
        pthread_mutex_unlock(&map->lock);
        (void)weak_map_wait_once(map, generation, &timeout);
    }
}

static st_index_t
weak_map_key_hash(weak_map_t *map, VALUE key)
{
    if (map->compare_keys_by_identity) {
        return (st_index_t)NUM2ULL(rb_obj_id(key));
    }
    return (st_index_t)NUM2LONG(rb_hash(key));
}

typedef struct {
    VALUE left;
    VALUE right;
} weak_map_eql_arguments_t;

static VALUE
weak_map_eql_protected(VALUE opaque)
{
    weak_map_eql_arguments_t *arguments = (weak_map_eql_arguments_t *)opaque;
    return rb_eql(arguments->left, arguments->right) ? Qtrue : Qfalse;
}

static bool
weak_map_keys_equal(
    weak_map_t *map,
    VALUE left,
    VALUE right,
    bool *stale,
    const weak_map_execution_context_t *execution
)
{
    *stale = false;
    if (map->compare_keys_by_identity) return left == right;

    weak_map_eql_arguments_t arguments = {.left = left, .right = right};
    uint64_t generation = map->generation;
    int state = 0;

    map->comparing = true;
    map->comparing_owner = execution->fiber;
    map->comparing_thread = execution->native_thread;
    pthread_mutex_unlock(&map->lock);

    VALUE result = rb_protect(weak_map_eql_protected, (VALUE)&arguments, &state);

    pthread_mutex_lock(&map->lock);
    *stale = map->generation != generation;
    map->comparing = false;
    map->comparing_owner = Qnil;
    weak_map_notify_waiters_locked(map);
    if (state) {
        pthread_mutex_unlock(&map->lock);
        rb_jump_tag(state);
    }
    return RTEST(result);
}

static size_t
weak_map_find_slot(
    weak_map_t *map,
    VALUE key,
    st_index_t hash,
    bool *found,
    const weak_map_execution_context_t *execution
)
{
    for (;;) {
        size_t mask = map->capacity - 1;
        size_t first_tombstone = SIZE_MAX;
        bool restart = false;

        for (size_t offset = 0; offset < map->capacity; offset++) {
            size_t index = ((size_t)hash + offset) & mask;
            weak_map_slot_t *slot = &map->slots[index];

            if (slot->state == WEAK_MAP_EMPTY) {
                *found = false;
                return first_tombstone == SIZE_MAX ? index : first_tombstone;
            }
            if (slot->state == WEAK_MAP_TOMBSTONE) {
                if (first_tombstone == SIZE_MAX) first_tombstone = index;
                continue;
            }
            if (slot->hash == hash) {
                bool stale;
                bool equal = weak_map_keys_equal(
                    map,
                    slot->key,
                    key,
                    &stale,
                    execution
                );

                if (stale) {
                    restart = true;
                    break;
                }
                if (equal) {
                    *found = true;
                    return index;
                }
            }
        }

        if (restart) continue;
        *found = false;
        return first_tombstone;
    }
}

static void
weak_map_resize(weak_map_t *map, size_t new_capacity)
{
    weak_map_slot_t *old_slots = map->slots;
    size_t old_capacity = map->capacity;
    map->slots = weak_map_allocate_slots_locked(map, new_capacity);
    map->capacity = new_capacity;
    map->size = 0;
    map->tombstones = 0;

    for (size_t index = 0; index < old_capacity; index++) {
        weak_map_slot_t *old = &old_slots[index];
        if (old->state != WEAK_MAP_OCCUPIED) continue;

        size_t mask = map->capacity - 1;
        size_t target = (size_t)old->hash & mask;
        while (map->slots[target].state == WEAK_MAP_OCCUPIED) {
            target = (target + 1) & mask;
        }
        map->slots[target] = *old;
        map->size++;
    }
    free(old_slots);
}

static void
weak_map_prepare_insert(weak_map_t *map)
{
    if ((map->size + map->tombstones + 1) * 10 >= map->capacity * 7) {
        weak_map_resize(map, map->capacity * 2);
    }
}

static VALUE
weak_map_store_locked(
    VALUE self,
    weak_map_t *map,
    VALUE key,
    VALUE value,
    st_index_t hash,
    const weak_map_execution_context_t *execution
)
{
    bool found;
    weak_map_prepare_insert(map);
    size_t index = weak_map_find_slot(map, key, hash, &found, execution);
    weak_map_slot_t *slot = &map->slots[index];
    if (!found) {
        if (slot->state == WEAK_MAP_TOMBSTONE) map->tombstones--;
        slot->key = key;
        slot->hash = hash;
        slot->state = WEAK_MAP_OCCUPIED;
        map->size++;
    }
    slot->value = value;
    RB_OBJ_WRITTEN(self, Qundef, key);
    RB_OBJ_WRITTEN(self, Qundef, value);
    weak_map_notify_waiters_locked(map);
    return value;
}

static VALUE
weak_map_prepare_key(weak_map_t *map, VALUE key)
{
    if (!map->compare_keys_by_identity && RB_TYPE_P(key, T_STRING) && !RB_OBJ_FROZEN(key)) {
        key = containers_normalize_string_key(key);
    }
    containers_check_shareable(key);
    return key;
}

typedef struct {
    VALUE self;
    weak_map_t *map;
} weak_map_init_context_t;

static int
weak_map_initialize_entry(VALUE key, VALUE value, VALUE opaque)
{
    weak_map_init_context_t *context = (weak_map_init_context_t *)opaque;
    key = weak_map_prepare_key(context->map, key);
    containers_check_shareable(value);
    st_index_t hash = weak_map_key_hash(context->map, key);
    weak_map_execution_context_t execution;
    weak_map_lock_state(context->map, &execution);
    weak_map_store_locked(context->self, context->map, key, value, hash, &execution);
    pthread_mutex_unlock(&context->map->lock);
    return ST_CONTINUE;
}

static VALUE
weak_map_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE mapping = Qnil;
    VALUE keywords = Qnil;
    ID keyword_ids[] = {
        rb_intern("compare_by_identity"),
        rb_intern("compare_keys_by_identity"),
        rb_intern("compare_values_by_identity")
    };
    VALUE keyword_values[3] = {Qundef, Qundef, Qundef};
    weak_map_t *map;

    rb_scan_args(argc, argv, "01:", &mapping, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 3, keyword_values);
    TypedData_Get_Struct(self, weak_map_t, &weak_map_type, map);
    if (map->initialized) rb_raise(rb_eRuntimeError, "weak map is already initialized");

    bool common = keyword_values[0] == Qundef
        ? false
        : containers_strict_bool(keyword_values[0], "compare_by_identity");
    map->compare_keys_by_identity = keyword_values[1] == Qundef
        ? common
        : containers_strict_bool(keyword_values[1], "compare_keys_by_identity");
    map->compare_values_by_identity = keyword_values[2] == Qundef
        ? common
        : containers_strict_bool(keyword_values[2], "compare_values_by_identity");
    map->capacity = WEAK_MAP_INITIAL_CAPACITY;
    map->slots = weak_map_allocate_slots(map->capacity);

    rb_gc_declare_weak_references(self);
    if (!NIL_P(mapping)) {
        Check_Type(mapping, T_HASH);
        weak_map_init_context_t context = {.self = self, .map = map};
        rb_hash_foreach(mapping, weak_map_initialize_entry, (VALUE)&context);
    }
    map->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static VALUE
weak_map_get(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    weak_map_execution_context_t execution;
    weak_map_lock_state(map, &execution);
    size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_fetch(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE default_value;
    rb_scan_args(argc, argv, "11", &key, &default_value);

    bool default_given = argc == 2;
    bool block_given = rb_block_given_p();
    if (block_given && default_given) {
        rb_warn("block supersedes default value argument");
    }

    VALUE original_key = key;
    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    weak_map_execution_context_t execution;
    weak_map_lock_state(map, &execution);
    size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);

    if (found) return result;
    if (block_given) return rb_yield(original_key);
    if (default_given) return default_value;
    containers_raise_key_error(self, original_key);
    return Qnil;
}

static VALUE
weak_map_set(VALUE self, VALUE key, VALUE value)
{
    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    containers_check_shareable(value);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_execution_context_t execution;
    weak_map_lock_for_update(map, &execution);
    weak_map_store_locked(self, map, key, value, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
weak_map_key_p(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    weak_map_execution_context_t execution;
    weak_map_lock_state(map, &execution);
    (void)weak_map_find_slot(map, key, hash, &found, &execution);
    pthread_mutex_unlock(&map->lock);
    return found ? Qtrue : Qfalse;
}

static VALUE
weak_map_getkey(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    weak_map_execution_context_t execution;
    weak_map_lock_state(map, &execution);
    size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->compare_keys_by_identity ? key : map->slots[index].key;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_delete(VALUE self, VALUE key)
{
    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    st_index_t hash = weak_map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    weak_map_execution_context_t execution;
    weak_map_lock_for_update(map, &execution);
    size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
    if (found) {
        weak_map_slot_t *slot = &map->slots[index];
        result = slot->value;
        slot->key = Qnil;
        slot->value = Qnil;
        slot->state = WEAK_MAP_TOMBSTONE;
        map->size--;
        map->tombstones++;
        weak_map_notify_waiters_locked(map);
    }
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_clear(VALUE self)
{
    weak_map_t *map = get_weak_map(self);
    weak_map_execution_context_t execution;
    weak_map_lock_for_update(map, &execution);
    for (size_t index = 0; index < map->capacity; index++) {
        weak_map_slot_t *slot = &map->slots[index];
        slot->key = Qnil;
        slot->value = Qnil;
        slot->hash = 0;
        slot->state = WEAK_MAP_EMPTY;
    }
    map->size = 0;
    map->tombstones = 0;
    weak_map_notify_waiters_locked(map);
    pthread_mutex_unlock(&map->lock);
    return self;
}

typedef struct {
    VALUE self;
    weak_map_t *map;
    VALUE key;
    VALUE current;
    VALUE argument;
    VALUE replacement;
    st_index_t hash;
    bool identity;
    bool complete;
} weak_map_operation_t;

static VALUE
weak_map_operation_cleanup(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    if (!operation->complete) {
        weak_map_execution_context_t execution;
        weak_map_lock_state(operation->map, &execution);
        weak_map_finish_update_locked(operation->map);
        weak_map_notify_waiters_locked(operation->map);
        pthread_mutex_unlock(&operation->map->lock);
    }
    return Qnil;
}

static VALUE
weak_map_store_body(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    VALUE result = rb_yield_values(0);
    containers_check_shareable(result);
    weak_map_execution_context_t execution;
    weak_map_lock_state(operation->map, &execution);
    weak_map_store_locked(
        operation->self,
        operation->map,
        operation->key,
        result,
        operation->hash,
        &execution
    );
    weak_map_finish_update_locked(operation->map);
    pthread_mutex_unlock(&operation->map->lock);
    operation->complete = true;
    return result;
}

static VALUE
weak_map_store_if_absent(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .complete = false,
    };
    rb_need_block();
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) return Qnil;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found, &execution);
    if (found) {
        VALUE value = map->slots[index].value;
        pthread_mutex_unlock(&map->lock);
        return value;
    }
    weak_map_begin_update_locked(map, &execution);
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(weak_map_store_body, (VALUE)&operation, weak_map_operation_cleanup, (VALUE)&operation);
}

static VALUE
weak_map_cas_body(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    bool matches = operation->identity
        ? operation->current == operation->argument
        : RTEST(rb_equal(operation->current, operation->argument));

    weak_map_execution_context_t execution;
    weak_map_lock_state(operation->map, &execution);
    if (matches) {
        weak_map_store_locked(
            operation->self,
            operation->map,
            operation->key,
            operation->replacement,
            operation->hash,
            &execution
        );
    }
    weak_map_finish_update_locked(operation->map);
    if (!matches) weak_map_notify_waiters_locked(operation->map);
    pthread_mutex_unlock(&operation->map->lock);
    operation->complete = true;
    return matches ? Qtrue : Qfalse;
}

static VALUE
weak_map_compare_and_set(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE expected;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "3:", &key, &expected, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .argument = expected,
        .replacement = replacement,
        .identity = map->compare_values_by_identity,
        .complete = false,
    };
    containers_check_shareable(expected);
    containers_check_shareable(replacement);
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) return Qfalse;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found, &execution);
    if (!found) {
        pthread_mutex_unlock(&map->lock);
        return Qfalse;
    }
    operation.current = map->slots[index].value;
    weak_map_begin_update_locked(map, &execution);
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(weak_map_cas_body, (VALUE)&operation, weak_map_operation_cleanup, (VALUE)&operation);
}

static VALUE
weak_map_upsert_body(VALUE opaque)
{
    weak_map_operation_t *operation = (weak_map_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    containers_check_shareable(result);
    weak_map_execution_context_t execution;
    weak_map_lock_state(operation->map, &execution);
    weak_map_store_locked(
        operation->self,
        operation->map,
        operation->key,
        result,
        operation->hash,
        &execution
    );
    weak_map_finish_update_locked(operation->map);
    pthread_mutex_unlock(&operation->map->lock);
    operation->complete = true;
    return result;
}

static VALUE
weak_map_upsert(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE initial;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &initial, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .complete = false,
    };
    containers_check_shareable(initial);
    rb_need_block();
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) return Qnil;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found, &execution);
    if (!found) {
        weak_map_store_locked(self, map, key, initial, operation.hash, &execution);
        pthread_mutex_unlock(&map->lock);
        return initial;
    }
    operation.current = map->slots[index].value;
    weak_map_begin_update_locked(map, &execution);
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(weak_map_upsert_body, (VALUE)&operation, weak_map_operation_cleanup, (VALUE)&operation);
}

static VALUE
weak_map_compare_keys_by_identity_p(VALUE self)
{
    return get_weak_map(self)->compare_keys_by_identity ? Qtrue : Qfalse;
}

static VALUE
weak_map_compare_values_by_identity_p(VALUE self)
{
    return get_weak_map(self)->compare_values_by_identity ? Qtrue : Qfalse;
}

static VALUE
weak_map_weak_keys_p(VALUE self)
{
    return get_weak_map(self)->weak_keys ? Qtrue : Qfalse;
}

static VALUE
weak_map_weak_values_p(VALUE self)
{
    return get_weak_map(self)->weak_values ? Qtrue : Qfalse;
}

static VALUE
weak_map_size(VALUE self)
{
    weak_map_t *map = get_weak_map(self);
    size_t size;
    weak_map_execution_context_t execution;
    weak_map_lock_state(map, &execution);
    size = map->size;
    pthread_mutex_unlock(&map->lock);
    return SIZET2NUM(size);
}

static VALUE
weak_map_enumerator_size(VALUE self, VALUE arguments, VALUE enumerator)
{
    (void)arguments;
    (void)enumerator;
    return weak_map_size(self);
}

static VALUE
weak_map_entries_snapshot(weak_map_t *map)
{
    for (;;) {
        size_t capacity;
        weak_map_execution_context_t execution;
        weak_map_lock_state(map, &execution);
        capacity = map->size;
        pthread_mutex_unlock(&map->lock);

        VALUE entries = rb_ary_new_capa((long)(capacity * 2));
        rb_ary_resize(entries, (long)(capacity * 2));
        weak_map_lock_state(map, &execution);
        if (map->size > capacity) {
            pthread_mutex_unlock(&map->lock);
            continue;
        }
        VALUE *entry_slots = RARRAY_PTR(entries);
        long entry_count = 0;
        for (size_t index = 0; index < map->capacity; index++) {
            weak_map_slot_t *slot = &map->slots[index];
            if (slot->state != WEAK_MAP_OCCUPIED) continue;
            RB_OBJ_WRITE(entries, &entry_slots[entry_count++], slot->key);
            RB_OBJ_WRITE(entries, &entry_slots[entry_count++], slot->value);
        }
        pthread_mutex_unlock(&map->lock);
        rb_ary_resize(entries, entry_count);
        return entries;
    }
}

static VALUE
weak_map_keys(VALUE self)
{
    VALUE entries = weak_map_entries_snapshot(get_weak_map(self));
    long entry_count = RARRAY_LEN(entries);
    VALUE keys = rb_ary_new_capa(entry_count / 2);
    for (long index = 0; index < entry_count; index += 2) {
        rb_ary_push(keys, RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return keys;
}

static VALUE
weak_map_each(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, weak_map_enumerator_size);
    VALUE entries = weak_map_entries_snapshot(get_weak_map(self));
    long entry_count = RARRAY_LEN(entries);
    for (long index = 0; index < entry_count; index += 2) {
        rb_yield(rb_assoc_new(RARRAY_AREF(entries, index), RARRAY_AREF(entries, index + 1)));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
weak_map_each_key(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, weak_map_enumerator_size);
    VALUE entries = weak_map_entries_snapshot(get_weak_map(self));
    long entry_count = RARRAY_LEN(entries);
    for (long index = 0; index < entry_count; index += 2) {
        rb_yield(RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
weak_map_each_value(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, weak_map_enumerator_size);
    VALUE entries = weak_map_entries_snapshot(get_weak_map(self));
    long entry_count = RARRAY_LEN(entries);
    for (long index = 1; index < entry_count; index += 2) {
        rb_yield(RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
weak_map_get_with_timeout(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) {
        return weak_map_timeout_result();
    }

    bool found;
    size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
    VALUE result = found ? map->slots[index].value : Qnil;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
weak_map_store_with_timeout(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE value;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &value, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    containers_check_shareable(value);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) {
        return weak_map_timeout_result();
    }
    weak_map_store_locked(self, map, key, value, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
weak_map_swap(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    containers_check_shareable(replacement);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );
    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) {
        return weak_map_timeout_result();
    }

    bool found;
    size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
    VALUE previous = found ? map->slots[index].value : Qnil;
    weak_map_store_locked(self, map, key, replacement, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return previous;
}

static bool
weak_map_values_equal(weak_map_t *map, VALUE left, VALUE right)
{
    return map->compare_values_by_identity ? left == right : RTEST(rb_equal(left, right));
}

static VALUE
weak_map_wait_for_value(int argc, VALUE *argv, VALUE self, bool non_nil)
{
    VALUE key;
    VALUE expected = Qnil;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    if (non_nil) rb_scan_args(argc, argv, "1:", &key, &keywords);
    else rb_scan_args(argc, argv, "2:", &key, &expected, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    if (!non_nil) containers_check_shareable(expected);
    st_index_t hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    for (;;) {
        bool found;
        VALUE current = Qnil;
        uint64_t generation;
        weak_map_execution_context_t execution;
        weak_map_lock_state(map, &execution);
        size_t index = weak_map_find_slot(map, key, hash, &found, &execution);
        if (found) current = map->slots[index].value;
        generation = map->generation;
        pthread_mutex_unlock(&map->lock);

        bool ready = non_nil ? !NIL_P(current) : !weak_map_values_equal(map, current, expected);
        if (ready) return current;

        weak_map_lock_state(map, &execution);
        if (map->generation != generation) {
            pthread_mutex_unlock(&map->lock);
            continue;
        }
        if (map->updating) weak_map_check_update_wait_locked(map, &execution);
        pthread_mutex_unlock(&map->lock);
        if (!weak_map_wait_once(map, generation, &timeout)) return weak_map_timeout_result();
    }
}

static VALUE
weak_map_wait_until_changed(int argc, VALUE *argv, VALUE self)
{
    return weak_map_wait_for_value(argc, argv, self, false);
}

static VALUE
weak_map_wait_until_non_nil(int argc, VALUE *argv, VALUE self)
{
    return weak_map_wait_for_value(argc, argv, self, true);
}

static VALUE
weak_map_update(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    weak_map_t *map = get_weak_map(self);
    key = weak_map_prepare_key(map, key);
    weak_map_operation_t operation = {
        .self = self,
        .map = map,
        .key = key,
        .complete = false,
    };
    rb_need_block();
    operation.hash = weak_map_key_hash(map, key);
    weak_map_timeout_t timeout = weak_map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    weak_map_execution_context_t execution;
    if (!weak_map_lock_for_update_with_timeout(map, &timeout, &execution)) return Qnil;
    bool found;
    size_t index = weak_map_find_slot(map, key, operation.hash, &found, &execution);
    operation.current = found ? map->slots[index].value : Qnil;
    weak_map_begin_update_locked(map, &execution);
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(
        weak_map_upsert_body,
        (VALUE)&operation,
        weak_map_operation_cleanup,
        (VALUE)&operation
    );
}

static void
define_weak_map_methods(VALUE klass)
{
    rb_define_alloc_func(klass, weak_map_allocate);
    rb_define_method(klass, "initialize", weak_map_initialize, -1);
    rb_define_method(klass, "[]", weak_map_get, 1);
    rb_define_method(klass, "[]=", weak_map_set, 2);
    rb_define_method(klass, "fetch", weak_map_fetch, -1);
    rb_define_method(klass, "get", weak_map_get_with_timeout, -1);
    rb_define_method(klass, "store", weak_map_store_with_timeout, -1);
    rb_define_method(klass, "swap", weak_map_swap, -1);
    rb_define_method(klass, "update", weak_map_update, -1);
    rb_define_method(klass, "wait_until_changed", weak_map_wait_until_changed, -1);
    rb_define_method(klass, "wait_until_non_nil", weak_map_wait_until_non_nil, -1);
    rb_define_method(klass, "store_if_absent", weak_map_store_if_absent, -1);
    rb_define_method(klass, "key?", weak_map_key_p, 1);
    rb_define_method(klass, "delete", weak_map_delete, 1);
    rb_define_method(klass, "clear", weak_map_clear, 0);
    rb_define_method(klass, "compare_and_set", weak_map_compare_and_set, -1);
    rb_define_method(klass, "upsert", weak_map_upsert, -1);
    rb_define_method(klass, "compare_keys_by_identity?", weak_map_compare_keys_by_identity_p, 0);
    rb_define_method(klass, "compare_values_by_identity?", weak_map_compare_values_by_identity_p, 0);
    rb_define_method(klass, "weak_keys?", weak_map_weak_keys_p, 0);
    rb_define_method(klass, "weak_values?", weak_map_weak_values_p, 0);
    rb_define_method(klass, "getkey", weak_map_getkey, 1);
    rb_define_method(klass, "size", weak_map_size, 0);
    rb_define_method(klass, "keys", weak_map_keys, 0);
    rb_define_method(klass, "each", weak_map_each, 0);
    rb_define_method(klass, "each_pair", weak_map_each, 0);
    rb_define_method(klass, "each_key", weak_map_each_key, 0);
    rb_define_method(klass, "each_value", weak_map_each_value, 0);
}

void
containers_init_weak_maps(VALUE namespace)
{
    cWeakKeyMap = rb_define_class_under(namespace, "WeakKeyMap", rb_cObject);
    cWeakValueMap = rb_define_class_under(namespace, "WeakValueMap", rb_cObject);
    cWeakMap = rb_define_class_under(namespace, "WeakMap", rb_cObject);
    define_weak_map_methods(cWeakKeyMap);
    define_weak_map_methods(cWeakValueMap);
    define_weak_map_methods(cWeakMap);
    rb_define_const(namespace, "NATIVE_WEAK_MAPS", Qtrue);
}

#else

void
containers_init_weak_maps(VALUE namespace)
{
    (void)namespace;
}

#endif
