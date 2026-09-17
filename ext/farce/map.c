#include "containers.h"
#include "ruby/fiber/scheduler.h"
#include "ruby/io.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define MAP_INITIAL_CAPACITY 16

static VALUE cMap;
static VALUE cUnsharedKeyLockMap;
static VALUE cSharedKeyLockMap;


typedef enum { MAP_EMPTY = 0, MAP_OCCUPIED = 1, MAP_TOMBSTONE = 2 } map_slot_state_t;

typedef struct {
    VALUE key;
    VALUE value;
    st_index_t hash;
    map_slot_state_t state;
} map_slot_t;

typedef struct map_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    struct map_waiter *next;
} map_waiter_t;

typedef struct map_reservation {
    VALUE key;
    st_index_t hash;
    VALUE fiber;
    VALUE thread;
    bool invalidated;
    struct map_reservation *next;
} map_reservation_t;

typedef struct {
    pthread_mutex_t lock;
    map_slot_t *slots;
    size_t capacity;
    size_t size;
    size_t tombstones;
    uint64_t generation;
    map_waiter_t *waiters;
    bool compare_keys_by_identity;
    bool compare_values_by_identity;
    bool comparing;
    VALUE comparing_owner;
    VALUE comparing_thread;
    map_reservation_t *reservations;
    atomic_size_t reservation_count;
    bool initialized;
} map_t;

enum { KEY_LOCK_UNINITIALIZED, KEY_LOCK_INITIALIZING, KEY_LOCK_PUBLISHING, KEY_LOCK_INITIALIZED };

/* Keep the map core first so its GC, waiter and reservation helpers can be
 * reused without changing the public Map layout or publication protocol. */
typedef struct {
    map_t core;
    atomic_int state;
} key_lock_map_t;

typedef struct {
    bool finite;
    double deadline;
} map_timeout_t;

typedef struct {
    VALUE fiber;
    VALUE thread;
    VALUE scheduler;
} map_execution_context_t;

/* Ruby's current Fiber/Thread accessors may allocate. Capture their values
 * before taking a native mutex so a Ractor GC barrier can never wait on a
 * peer that is blocked on that mutex. */
static map_execution_context_t
map_current_execution_context(void)
{
    map_execution_context_t context = {
        .fiber = rb_fiber_current(),
        .thread = rb_thread_current(),
        .scheduler = rb_fiber_scheduler_current(),
    };
    return context;
}

static double
map_monotonic_now(void)
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

static map_timeout_t
map_parse_timeout(VALUE timeout)
{
    map_timeout_t parsed = {.finite = false, .deadline = 0};
    if (NIL_P(timeout)) return parsed;
    double seconds = NUM2DBL(timeout);
    if (!isfinite(seconds) || seconds < 0) {
        rb_raise(rb_eArgError, "timeout must be a finite, non-negative number or nil");
    }
    parsed.finite = true;
    parsed.deadline = map_monotonic_now() + seconds;
    return parsed;
}

static void
map_set_fd_flags(int fd)
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
map_waiter_initialize(map_waiter_t *waiter)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) rb_sys_fail("pipe");
    waiter->read_fd = descriptors[0];
    waiter->write_fd = descriptors[1];
    waiter->notified = false;
    waiter->next = NULL;
    map_set_fd_flags(waiter->read_fd);
    map_set_fd_flags(waiter->write_fd);
}

static void
map_notify_waiters_locked(map_t *map)
{
    unsigned char byte = 1;
    map->generation++;
    for (map_waiter_t *waiter = map->waiters; waiter; waiter = waiter->next) {
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
map_mark(void *pointer)
{
    map_t *map = pointer;
    rb_gc_mark_movable(map->comparing_owner);
    rb_gc_mark_movable(map->comparing_thread);
    for (map_reservation_t *reservation = map->reservations; reservation; reservation = reservation->next) {
        rb_gc_mark_movable(reservation->key);
        rb_gc_mark_movable(reservation->fiber);
        rb_gc_mark_movable(reservation->thread);
    }
    if (!map->slots) return;
    for (size_t index = 0; index < map->capacity; index++) {
        if (map->slots[index].state == MAP_OCCUPIED) {
            rb_gc_mark_movable(map->slots[index].key);
            rb_gc_mark_movable(map->slots[index].value);
        }
    }
}

static void
map_compact(void *pointer)
{
    map_t *map = pointer;
    map->comparing_owner = rb_gc_location(map->comparing_owner);
    map->comparing_thread = rb_gc_location(map->comparing_thread);
    for (map_reservation_t *reservation = map->reservations; reservation; reservation = reservation->next) {
        reservation->key = rb_gc_location(reservation->key);
        reservation->fiber = rb_gc_location(reservation->fiber);
        reservation->thread = rb_gc_location(reservation->thread);
    }
    if (!map->slots) return;
    for (size_t index = 0; index < map->capacity; index++) {
        if (map->slots[index].state == MAP_OCCUPIED) {
            map->slots[index].key = rb_gc_location(map->slots[index].key);
            map->slots[index].value = rb_gc_location(map->slots[index].value);
        }
    }
}

static void
map_free(void *pointer)
{
    map_t *map = pointer;
    pthread_mutex_destroy(&map->lock);
    free(map->slots);
    while (map->reservations) {
        map_reservation_t *reservation = map->reservations;
        map->reservations = reservation->next;
        free(reservation);
    }
    ruby_xfree(map);
}

static size_t
map_memsize(const void *pointer)
{
    const map_t *map = pointer;
    if (!map) return 0;
    size_t reservations = atomic_load_explicit(&map->reservation_count, memory_order_relaxed);
    return sizeof(map_t) + map->capacity * sizeof(map_slot_t) + reservations * sizeof(map_reservation_t);
}

static const rb_data_type_t map_type = {
    .wrap_struct_name = "Ractor::Containers::Map",
    .function = {
        .dmark = map_mark,
        .dfree = map_free,
        .dsize = map_memsize,
        .dcompact = map_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static size_t
key_lock_memsize(const void *pointer)
{
    if (!pointer) return 0;
    return map_memsize(pointer) + sizeof(key_lock_map_t) - sizeof(map_t);
}

/* Local reservations may retain arbitrary Ruby keys. They must never use the
 * frozen-shareable Map type, including while a loader is running. */
static const rb_data_type_t unshared_key_lock_type = {
    .wrap_struct_name = "Farce::Internal::UnsharedKeyLockMap",
    .function = {
        .dmark = map_mark,
        .dfree = map_free,
        .dsize = key_lock_memsize,
        .dcompact = map_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static const rb_data_type_t shared_key_lock_type = {
    .wrap_struct_name = "Farce::Internal::SharedKeyLockMap",
    .function = {
        .dmark = map_mark,
        .dfree = map_free,
        .dsize = key_lock_memsize,
        .dcompact = map_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static map_slot_t *
allocate_slots(size_t capacity)
{
    map_slot_t *slots = calloc(capacity, sizeof(map_slot_t));
    if (!slots) rb_memerror();
    return slots;
}

static void
map_initialize_storage(map_t *map)
{
    pthread_mutex_init(&map->lock, NULL);
    map->slots = NULL;
    map->capacity = 0;
    map->size = 0;
    map->tombstones = 0;
    map->generation = 0;
    map->waiters = NULL;
    map->compare_keys_by_identity = false;
    map->compare_values_by_identity = false;
    map->comparing = false;
    map->comparing_owner = Qnil;
    map->comparing_thread = Qnil;
    map->reservations = NULL;
    atomic_init(&map->reservation_count, 0);
    map->initialized = false;
}

static VALUE
map_allocate(VALUE klass)
{
    map_t *map;
    VALUE object = TypedData_Make_Struct(klass, map_t, &map_type, map);
    map_initialize_storage(map);
    return object;
}

static VALUE
key_lock_allocate(VALUE klass, const rb_data_type_t *type)
{
    key_lock_map_t *map;
    VALUE object = TypedData_Make_Struct(klass, key_lock_map_t, type, map);
    map_initialize_storage(&map->core);
    atomic_init(&map->state, KEY_LOCK_UNINITIALIZED);
    return object;
}

static VALUE
shared_key_lock_allocate(VALUE klass)
{
    return key_lock_allocate(klass, &shared_key_lock_type);
}

static VALUE
unshared_key_lock_allocate(VALUE klass)
{
    VALUE self = key_lock_allocate(klass, &unshared_key_lock_type);
    VALUE guard = rb_path2class("Farce::Internal::Unshareable");
    rb_funcall(guard, rb_intern("pin_to_current_ractor"), 1, self);
    return self;
}

static map_t *
get_map(VALUE self)
{
    map_t *map;
    TypedData_Get_Struct(self, map_t, &map_type, map);
    if (!map->initialized) rb_raise(rb_eRuntimeError, "uninitialized Map");
    return map;
}

typedef struct {
    map_t *map;
    map_waiter_t *waiter;
    map_timeout_t *timeout;
    bool registered;
} map_wait_context_t;

static VALUE
map_wait_body(VALUE opaque)
{
    map_wait_context_t *context = (map_wait_context_t *)opaque;
    VALUE wait_timeout = Qnil;
    if (context->timeout->finite) {
        double remaining = context->timeout->deadline - map_monotonic_now();
        if (remaining <= 0) return Qfalse;
        wait_timeout = DBL2NUM(remaining);
    }
    return containers_wait_for_readable(context->waiter->read_fd, wait_timeout) ? Qtrue : Qfalse;
}

static VALUE
map_wait_cleanup(VALUE opaque)
{
    map_wait_context_t *context = (map_wait_context_t *)opaque;
    if (context->registered) {
        pthread_mutex_lock(&context->map->lock);
        map_waiter_t **cursor = &context->map->waiters;
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
map_wait_once(map_t *map, uint64_t generation, map_timeout_t *timeout)
{
    map_waiter_t waiter;
    map_waiter_initialize(&waiter);

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

    map_wait_context_t context = {
        .map = map,
        .waiter = &waiter,
        .timeout = timeout,
        .registered = true,
    };
    return RTEST(rb_ensure(map_wait_body, (VALUE)&context, map_wait_cleanup, (VALUE)&context));
}

/* Acquire the short native state mutex, waiting outside the runtime lock if a
 * key equality callback currently owns the map's logical critical section.
 * The common path is one branch after pthread_mutex_lock. */
static void
map_lock_state(map_t *map, const map_execution_context_t *context)
{
    map_timeout_t timeout = {.finite = false, .deadline = 0};

    for (;;) {
        pthread_mutex_lock(&map->lock);
        if (!map->comparing) return;

        if (map->comparing_owner == context->fiber) {
            pthread_mutex_unlock(&map->lock);
            rb_raise(rb_eThreadError, "recursive map access from key equality");
        }
        if (map->comparing_thread == context->thread && NIL_P(context->scheduler)) {
            pthread_mutex_unlock(&map->lock);
            rb_raise(
                rb_eThreadError,
                "deadlock; map key equality is owned by another unscheduled fiber"
            );
        }

        uint64_t generation = map->generation;
        pthread_mutex_unlock(&map->lock);
        (void)map_wait_once(map, generation, &timeout);
    }
}

static VALUE
map_timeout_result(void)
{
    return rb_block_given_p() ? rb_yield_values(0) : Qnil;
}

static st_index_t
map_key_hash(map_t *map, VALUE key)
{
    if (map->compare_keys_by_identity) {
        return (st_index_t)NUM2ULL(rb_obj_id(key));
    }
    return (st_index_t)NUM2LONG(rb_hash(key));
}

typedef struct {
    VALUE left;
    VALUE right;
} map_eql_arguments_t;

static VALUE
map_eql_protected(VALUE opaque)
{
    map_eql_arguments_t *arguments = (map_eql_arguments_t *)opaque;
    return rb_eql(arguments->left, arguments->right) ? Qtrue : Qfalse;
}

/* Called with map->lock held and returns with it held unless equality raises.
 * The logical comparison gate preserves the original operation-wide
 * exclusion while rb_io_wait lets other Threads/Ractors/Fibers park without
 * starving the Ruby callback. */
static bool
map_keys_equal(
    map_t *map,
    VALUE left,
    VALUE right,
    const map_execution_context_t *context
)
{
    if (map->compare_keys_by_identity) return left == right;

    map_eql_arguments_t arguments = {.left = left, .right = right};
    int state = 0;

    map->comparing = true;
    map->comparing_owner = context->fiber;
    map->comparing_thread = context->thread;
    pthread_mutex_unlock(&map->lock);

    VALUE result = rb_protect(map_eql_protected, (VALUE)&arguments, &state);

    pthread_mutex_lock(&map->lock);
    map->comparing = false;
    map->comparing_owner = Qnil;
    map->comparing_thread = Qnil;
    map_notify_waiters_locked(map);
    if (state) {
        pthread_mutex_unlock(&map->lock);
        rb_jump_tag(state);
    }
    return RTEST(result);
}

static size_t
map_find_slot(
    map_t *map,
    VALUE key,
    st_index_t hash,
    bool *found,
    const map_execution_context_t *context
)
{
    size_t mask = map->capacity - 1;
    size_t first_tombstone = SIZE_MAX;

    for (size_t offset = 0; offset < map->capacity; offset++) {
        size_t index = ((size_t)hash + offset) & mask;
        map_slot_t *slot = &map->slots[index];

        if (slot->state == MAP_EMPTY) {
            *found = false;
            return first_tombstone == SIZE_MAX ? index : first_tombstone;
        }
        if (slot->state == MAP_TOMBSTONE) {
            if (first_tombstone == SIZE_MAX) first_tombstone = index;
            continue;
        }
        if (slot->hash == hash && map_keys_equal(map, slot->key, key, context)) {
            *found = true;
            return index;
        }
    }

    *found = false;
    return first_tombstone;
}

/* Reservations use the same hash and equality rules as stored entries. They
 * are kept separately so a missing key remains missing while user code runs. */
static map_reservation_t *
map_find_reservation_locked(
    map_t *map,
    VALUE key,
    st_index_t hash,
    const map_execution_context_t *context
)
{
    for (map_reservation_t *reservation = map->reservations; reservation; reservation = reservation->next) {
        if (!reservation->invalidated && reservation->hash == hash &&
            map_keys_equal(map, reservation->key, key, context)) {
            return reservation;
        }
    }
    return NULL;
}

static void
map_check_reservation_wait_locked(
    map_t *map,
    map_reservation_t *reservation,
    const map_execution_context_t *context
)
{
    if (reservation->fiber == context->fiber) {
        pthread_mutex_unlock(&map->lock);
        rb_raise(rb_eThreadError, "deadlock; recursive map access during an update");
    }
    if (reservation->thread == context->thread && NIL_P(context->scheduler)) {
        pthread_mutex_unlock(&map->lock);
        rb_raise(
            rb_eThreadError,
            "deadlock; map update is owned by another unscheduled fiber"
        );
    }
}

static bool
map_lock_for_key_with_timeout(
    map_t *map,
    VALUE key,
    st_index_t hash,
    map_timeout_t *timeout,
    const map_execution_context_t *context
)
{
    for (;;) {
        map_lock_state(map, context);
        map_reservation_t *reservation = map_find_reservation_locked(map, key, hash, context);
        if (!reservation) return true;
        map_check_reservation_wait_locked(map, reservation, context);
        uint64_t generation = map->generation;
        pthread_mutex_unlock(&map->lock);
        if (!map_wait_once(map, generation, timeout)) return false;
    }
}

static void
map_lock_for_key(
    map_t *map,
    VALUE key,
    st_index_t hash,
    const map_execution_context_t *context
)
{
    map_timeout_t timeout = {.finite = false, .deadline = 0};
    (void)map_lock_for_key_with_timeout(map, key, hash, &timeout, context);
}

static map_reservation_t *
map_begin_reservation_locked(
    map_t *map,
    VALUE key,
    st_index_t hash,
    const map_execution_context_t *context
)
{
    map_reservation_t *reservation = malloc(sizeof(map_reservation_t));
    if (!reservation) {
        pthread_mutex_unlock(&map->lock);
        rb_memerror();
    }
    reservation->key = key;
    reservation->hash = hash;
    reservation->fiber = context->fiber;
    reservation->thread = context->thread;
    reservation->invalidated = false;
    reservation->next = map->reservations;
    map->reservations = reservation;
    atomic_fetch_add_explicit(&map->reservation_count, 1, memory_order_relaxed);
    return reservation;
}

static void
map_finish_reservation_locked(map_t *map, map_reservation_t *reservation)
{
    map_reservation_t **cursor = &map->reservations;
    while (*cursor && *cursor != reservation) cursor = &(*cursor)->next;
    if (*cursor) {
        *cursor = reservation->next;
        atomic_fetch_sub_explicit(&map->reservation_count, 1, memory_order_relaxed);
    }
    map_notify_waiters_locked(map);
    free(reservation);
}

static void
map_invalidate_reservations_locked(map_t *map)
{
    for (map_reservation_t *reservation = map->reservations; reservation; reservation = reservation->next) {
        reservation->invalidated = true;
    }
}

static void
map_resize(map_t *map, size_t new_capacity)
{
    map_slot_t *old_slots = map->slots;
    size_t old_capacity = map->capacity;
    map_slot_t *new_slots = calloc(new_capacity, sizeof(map_slot_t));
    if (!new_slots) {
        pthread_mutex_unlock(&map->lock);
        rb_memerror();
    }
    map->slots = new_slots;
    map->capacity = new_capacity;
    map->size = 0;
    map->tombstones = 0;

    for (size_t index = 0; index < old_capacity; index++) {
        map_slot_t *old = &old_slots[index];
        if (old->state == MAP_OCCUPIED) {
            size_t mask = map->capacity - 1;
            size_t target = (size_t)old->hash & mask;
            while (map->slots[target].state == MAP_OCCUPIED) {
                target = (target + 1) & mask;
            }
            map->slots[target] = *old;
            map->size++;
        }
    }
    free(old_slots);
}

static void
map_prepare_insert(map_t *map)
{
    if ((map->size + map->tombstones + 1) * 10 >= map->capacity * 7) {
        map_resize(map, map->capacity * 2);
    }
}

static VALUE
map_store_locked(
    map_t *map,
    VALUE key,
    VALUE value,
    st_index_t hash,
    const map_execution_context_t *context
)
{
    bool found;
    map_prepare_insert(map);
    size_t index = map_find_slot(map, key, hash, &found, context);
    map_slot_t *slot = &map->slots[index];
    if (!found) {
        if (slot->state == MAP_TOMBSTONE) map->tombstones--;
        slot->key = key;
        slot->hash = hash;
        slot->state = MAP_OCCUPIED;
        map->size++;
    }
    slot->value = value;
    map_notify_waiters_locked(map);
    return value;
}

typedef struct {
    map_t *map;
    map_execution_context_t execution;
} map_init_context_t;

static int
map_initialize_entry(VALUE key, VALUE value, VALUE opaque)
{
    map_init_context_t *context = (map_init_context_t *)opaque;
    containers_check_shareable(key);
    containers_check_shareable(value);
    st_index_t hash = map_key_hash(context->map, key);
    map_lock_state(context->map, &context->execution);
    map_store_locked(context->map, key, value, hash, &context->execution);
    pthread_mutex_unlock(&context->map->lock);
    return ST_CONTINUE;
}

static VALUE
map_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE mapping = Qnil;
    VALUE keywords = Qnil;
    ID keyword_ids[] = {
        rb_intern("compare_by_identity"),
        rb_intern("compare_keys_by_identity"),
        rb_intern("compare_values_by_identity")
    };
    VALUE keyword_values[3] = {Qundef, Qundef, Qundef};
    map_t *map;

    rb_scan_args(argc, argv, "01:", &mapping, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 3, keyword_values);
    TypedData_Get_Struct(self, map_t, &map_type, map);
    if (map->initialized) rb_raise(rb_eRuntimeError, "Map is already initialized");

    bool common = keyword_values[0] == Qundef
        ? false
        : containers_strict_bool(keyword_values[0], "compare_by_identity");
    map->compare_keys_by_identity = keyword_values[1] == Qundef
        ? common
        : containers_strict_bool(keyword_values[1], "compare_keys_by_identity");
    map->compare_values_by_identity = keyword_values[2] == Qundef
        ? common
        : containers_strict_bool(keyword_values[2], "compare_values_by_identity");
    map->capacity = MAP_INITIAL_CAPACITY;
    map->slots = allocate_slots(map->capacity);

    if (!NIL_P(mapping)) {
        Check_Type(mapping, T_HASH);
        map_init_context_t context = {
            .map = map,
            .execution = map_current_execution_context(),
        };
        rb_hash_foreach(mapping, map_initialize_entry, (VALUE)&context);
    }
    map->initialized = true;
    containers_finish_initialization(self);
    return self;
}

static VALUE
map_get(VALUE self, VALUE key)
{
    map_t *map = get_map(self);
    containers_check_shareable(key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
map_fetch(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE default_value;
    rb_scan_args(argc, argv, "11", &key, &default_value);

    bool default_given = argc == 2;
    bool block_given = rb_block_given_p();
    if (block_given && default_given) {
        rb_warn("block supersedes default value argument");
    }

    map_t *map = get_map(self);
    containers_check_shareable(key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);

    if (found) return result;
    if (block_given) return rb_yield(key);
    if (default_given) return default_value;
    containers_raise_key_error(self, key);
    return Qnil;
}

static VALUE
map_set(VALUE self, VALUE key, VALUE value)
{
    map_t *map = get_map(self);
    containers_check_shareable(key);
    containers_check_shareable(value);
    st_index_t hash = map_key_hash(map, key);
    map_execution_context_t execution = map_current_execution_context();
    map_lock_for_key(map, key, hash, &execution);
    map_store_locked(map, key, value, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
map_key_p(VALUE self, VALUE key)
{
    map_t *map = get_map(self);
    containers_check_shareable(key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    (void)map_find_slot(map, key, hash, &found, &execution);
    pthread_mutex_unlock(&map->lock);
    return found ? Qtrue : Qfalse;
}

static VALUE
map_getkey(VALUE self, VALUE key)
{
    map_t *map = get_map(self);
    containers_check_shareable(key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->compare_keys_by_identity ? key : map->slots[index].key;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
map_delete(VALUE self, VALUE key)
{
    map_t *map = get_map(self);
    containers_check_shareable(key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_for_key(map, key, hash, &execution);
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (found) {
        map_slot_t *slot = &map->slots[index];
        result = slot->value;
        slot->key = Qnil;
        slot->value = Qnil;
        slot->state = MAP_TOMBSTONE;
        map->size--;
        map->tombstones++;
        map_notify_waiters_locked(map);
    }
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
map_clear(VALUE self)
{
    map_t *map = get_map(self);
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    map_invalidate_reservations_locked(map);
    for (size_t index = 0; index < map->capacity; index++) {
        map_slot_t *slot = &map->slots[index];
        slot->key = Qnil;
        slot->value = Qnil;
        slot->hash = 0;
        slot->state = MAP_EMPTY;
    }
    map->size = 0;
    map->tombstones = 0;
    map_notify_waiters_locked(map);
    pthread_mutex_unlock(&map->lock);
    return self;
}

typedef struct {
    map_t *map;
    map_execution_context_t execution;
    VALUE key;
    VALUE current;
    VALUE argument;
    VALUE replacement;
    st_index_t hash;
    map_reservation_t *reservation;
    bool identity;
    bool complete;
} map_operation_t;

static VALUE
map_operation_cleanup(VALUE opaque)
{
    map_operation_t *operation = (map_operation_t *)opaque;
    if (!operation->complete) {
        map_lock_state(operation->map, &operation->execution);
        map_finish_reservation_locked(operation->map, operation->reservation);
        pthread_mutex_unlock(&operation->map->lock);
    }
    return Qnil;
}

static VALUE
map_store_body(VALUE opaque)
{
    map_operation_t *operation = (map_operation_t *)opaque;
    VALUE result = rb_yield_values(0);
    containers_check_shareable(result);
    map_lock_state(operation->map, &operation->execution);
    bool stored = !operation->reservation->invalidated;
    if (stored) {
        map_store_locked(
            operation->map,
            operation->key,
            result,
            operation->hash,
            &operation->execution
        );
    }
    operation->complete = true;
    map_finish_reservation_locked(operation->map, operation->reservation);
    pthread_mutex_unlock(&operation->map->lock);
    return stored ? result : Qnil;
}

static VALUE
map_store_if_absent(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    map_operation_t operation = {
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    containers_check_shareable(key);
    rb_need_block();
    operation.hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qnil;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (found) {
        VALUE value = map->slots[index].value;
        pthread_mutex_unlock(&map->lock);
        return value;
    }
    operation.reservation = map_begin_reservation_locked(
        map, key, operation.hash, &operation.execution
    );
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(map_store_body, (VALUE)&operation, map_operation_cleanup, (VALUE)&operation);
}

static VALUE
map_cas_body(VALUE opaque)
{
    map_operation_t *operation = (map_operation_t *)opaque;
    bool matches = operation->identity
        ? operation->current == operation->argument
        : RTEST(rb_equal(operation->current, operation->argument));

    map_lock_state(operation->map, &operation->execution);
    bool replaced = matches && !operation->reservation->invalidated;
    if (replaced) {
        map_store_locked(
            operation->map,
            operation->key,
            operation->replacement,
            operation->hash,
            &operation->execution
        );
    }
    operation->complete = true;
    map_finish_reservation_locked(operation->map, operation->reservation);
    pthread_mutex_unlock(&operation->map->lock);
    return replaced ? Qtrue : Qfalse;
}

static VALUE
map_compare_and_set(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE expected;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "3:", &key, &expected, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    map_operation_t operation = {
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .argument = expected,
        .replacement = replacement,
        .identity = map->compare_values_by_identity,
        .complete = false,
    };
    containers_check_shareable(key);
    containers_check_shareable(expected);
    containers_check_shareable(replacement);
    operation.hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qfalse;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (!found) {
        pthread_mutex_unlock(&map->lock);
        return Qfalse;
    }
    operation.current = map->slots[index].value;
    operation.reservation = map_begin_reservation_locked(
        map, key, operation.hash, &operation.execution
    );
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(map_cas_body, (VALUE)&operation, map_operation_cleanup, (VALUE)&operation);
}

static VALUE
map_upsert_body(VALUE opaque)
{
    map_operation_t *operation = (map_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    containers_check_shareable(result);
    map_lock_state(operation->map, &operation->execution);
    bool stored = !operation->reservation->invalidated;
    if (stored) {
        map_store_locked(
            operation->map,
            operation->key,
            result,
            operation->hash,
            &operation->execution
        );
    }
    operation->complete = true;
    map_finish_reservation_locked(operation->map, operation->reservation);
    pthread_mutex_unlock(&operation->map->lock);
    return stored ? result : Qnil;
}

static VALUE
map_upsert(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE initial;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &initial, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    map_operation_t operation = {
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    containers_check_shareable(key);
    containers_check_shareable(initial);
    rb_need_block();
    operation.hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qnil;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (!found) {
        map_store_locked(map, key, initial, operation.hash, &operation.execution);
        pthread_mutex_unlock(&map->lock);
        return initial;
    }
    operation.current = map->slots[index].value;
    operation.reservation = map_begin_reservation_locked(
        map, key, operation.hash, &operation.execution
    );
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(map_upsert_body, (VALUE)&operation, map_operation_cleanup, (VALUE)&operation);
}

static VALUE
map_compare_keys_by_identity_p(VALUE self)
{
    return get_map(self)->compare_keys_by_identity ? Qtrue : Qfalse;
}

static VALUE
map_compare_values_by_identity_p(VALUE self)
{
    return get_map(self)->compare_values_by_identity ? Qtrue : Qfalse;
}

static VALUE
map_size(VALUE self)
{
    map_t *map = get_map(self);
    size_t size;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    size = map->size;
    pthread_mutex_unlock(&map->lock);
    return SIZET2NUM(size);
}

static VALUE
map_enumerator_size(VALUE self, VALUE arguments, VALUE enumerator)
{
    (void)arguments;
    (void)enumerator;
    return map_size(self);
}

static VALUE
map_entries_snapshot(map_t *map)
{
    map_execution_context_t execution = map_current_execution_context();
    for (;;) {
        size_t capacity;
        map_lock_state(map, &execution);
        capacity = map->size;
        pthread_mutex_unlock(&map->lock);

        long reserved_entries = (long)(capacity * 2);
        VALUE entries = rb_ary_new_capa(reserved_entries);
        rb_ary_resize(entries, reserved_entries);
        map_lock_state(map, &execution);
        if (map->size > capacity) {
            pthread_mutex_unlock(&map->lock);
            continue;
        }
        long entry_count = 0;
        VALUE *storage = RARRAY_PTR(entries);
        for (size_t index = 0; index < map->capacity; index++) {
            map_slot_t *slot = &map->slots[index];
            if (slot->state != MAP_OCCUPIED) continue;
            RB_OBJ_WRITE(entries, &storage[entry_count++], slot->key);
            RB_OBJ_WRITE(entries, &storage[entry_count++], slot->value);
        }
        pthread_mutex_unlock(&map->lock);
        if (entry_count < reserved_entries) rb_ary_resize(entries, entry_count);
        return entries;
    }
}

static VALUE
map_keys(VALUE self)
{
    VALUE entries = map_entries_snapshot(get_map(self));
    long entry_count = RARRAY_LEN(entries);
    VALUE keys = rb_ary_new_capa(entry_count / 2);
    for (long index = 0; index < entry_count; index += 2) {
        rb_ary_push(keys, RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return keys;
}

static VALUE
map_each(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, map_enumerator_size);
    VALUE entries = map_entries_snapshot(get_map(self));
    long entry_count = RARRAY_LEN(entries);
    for (long index = 0; index < entry_count; index += 2) {
        rb_yield(rb_assoc_new(RARRAY_AREF(entries, index), RARRAY_AREF(entries, index + 1)));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
map_each_key(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, map_enumerator_size);
    VALUE entries = map_entries_snapshot(get_map(self));
    long entry_count = RARRAY_LEN(entries);
    for (long index = 0; index < entry_count; index += 2) {
        rb_yield(RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
map_each_value(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, map_enumerator_size);
    VALUE entries = map_entries_snapshot(get_map(self));
    long entry_count = RARRAY_LEN(entries);
    for (long index = 1; index < entry_count; index += 2) {
        rb_yield(RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
map_get_with_timeout(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    containers_check_shareable(key);
    st_index_t hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);
    map_execution_context_t execution = map_current_execution_context();
    if (!map_lock_for_key_with_timeout(map, key, hash, &timeout, &execution)) {
        return map_timeout_result();
    }

    bool found;
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    VALUE result = found ? map->slots[index].value : Qnil;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
map_store_with_timeout(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE value;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &value, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    containers_check_shareable(key);
    containers_check_shareable(value);
    st_index_t hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);
    map_execution_context_t execution = map_current_execution_context();
    if (!map_lock_for_key_with_timeout(map, key, hash, &timeout, &execution)) {
        return map_timeout_result();
    }
    map_store_locked(map, key, value, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
map_swap(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    containers_check_shareable(key);
    containers_check_shareable(replacement);
    st_index_t hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);
    map_execution_context_t execution = map_current_execution_context();
    if (!map_lock_for_key_with_timeout(map, key, hash, &timeout, &execution)) {
        return map_timeout_result();
    }

    bool found;
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    VALUE previous = found ? map->slots[index].value : Qnil;
    map_store_locked(map, key, replacement, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return previous;
}

static bool
map_values_equal(map_t *map, VALUE left, VALUE right)
{
    return map->compare_values_by_identity ? left == right : RTEST(rb_equal(left, right));
}

static VALUE
map_wait_for_value(int argc, VALUE *argv, VALUE self, bool non_nil)
{
    VALUE key;
    VALUE expected = Qnil;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    if (non_nil) rb_scan_args(argc, argv, "1:", &key, &keywords);
    else rb_scan_args(argc, argv, "2:", &key, &expected, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    containers_check_shareable(key);
    if (!non_nil) containers_check_shareable(expected);
    st_index_t hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);
    map_execution_context_t execution = map_current_execution_context();

    for (;;) {
        bool found;
        VALUE current = Qnil;
        uint64_t generation;
        map_lock_state(map, &execution);
        size_t index = map_find_slot(map, key, hash, &found, &execution);
        if (found) current = map->slots[index].value;
        generation = map->generation;
        pthread_mutex_unlock(&map->lock);

        bool ready = non_nil ? !NIL_P(current) : !map_values_equal(map, current, expected);
        if (ready) return current;

        map_lock_state(map, &execution);
        if (map->generation != generation) {
            pthread_mutex_unlock(&map->lock);
            continue;
        }
        map_reservation_t *reservation = map_find_reservation_locked(map, key, hash, &execution);
        if (reservation) map_check_reservation_wait_locked(map, reservation, &execution);
        pthread_mutex_unlock(&map->lock);
        if (!map_wait_once(map, generation, &timeout)) return map_timeout_result();
    }
}

static VALUE
map_wait_until_changed(int argc, VALUE *argv, VALUE self)
{
    return map_wait_for_value(argc, argv, self, false);
}

static VALUE
map_wait_until_non_nil(int argc, VALUE *argv, VALUE self)
{
    return map_wait_for_value(argc, argv, self, true);
}

static VALUE
map_update(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    map_operation_t operation = {
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    containers_check_shareable(key);
    rb_need_block();
    operation.hash = map_key_hash(map, key);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qnil;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    operation.current = found ? map->slots[index].value : Qnil;
    operation.reservation = map_begin_reservation_locked(
        map, key, operation.hash, &operation.execution
    );
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(map_upsert_body, (VALUE)&operation, map_operation_cleanup, (VALUE)&operation);
}

static key_lock_map_t *
key_lock_get_raw(VALUE self)
{
    key_lock_map_t *map;
    if (rb_typeddata_is_kind_of(self, &unshared_key_lock_type)) {
        TypedData_Get_Struct(self, key_lock_map_t, &unshared_key_lock_type, map);
    }
    else {
        TypedData_Get_Struct(self, key_lock_map_t, &shared_key_lock_type, map);
    }
    return map;
}

static VALUE
key_lock_publish(VALUE self)
{
    containers_finish_initialization(self);
    return self;
}

static VALUE
key_lock_finish_publication(VALUE self)
{
    key_lock_map_t *map = key_lock_get_raw(self);
    int state = rb_ractor_shareable_p(self) ? KEY_LOCK_INITIALIZED : KEY_LOCK_UNINITIALIZED;
    atomic_store_explicit(&map->state, state, memory_order_release);
    return Qnil;
}

static VALUE
key_lock_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE keywords = Qnil;
    ID ids[] = {
        rb_intern("compare_by_identity"),
        rb_intern("compare_keys_by_identity"),
        rb_intern("compare_values_by_identity")
    };
    VALUE values[3] = {Qundef, Qundef, Qundef};
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, ids, 0, 3, values);
    key_lock_map_t *map = key_lock_get_raw(self);
    if (atomic_load_explicit(&map->state, memory_order_acquire) != KEY_LOCK_UNINITIALIZED) {
        rb_raise(rb_eRuntimeError, "key lock map is already initialized");
    }
    rb_check_frozen(self);
    bool common = values[0] == Qundef ? false : containers_strict_bool(values[0], "compare_by_identity");
    bool keys = values[1] == Qundef ? common : containers_strict_bool(values[1], "compare_keys_by_identity");
    if (values[2] != Qundef) containers_strict_bool(values[2], "compare_values_by_identity");
    int expected = KEY_LOCK_UNINITIALIZED;
    if (!atomic_compare_exchange_strong(&map->state, &expected, KEY_LOCK_INITIALIZING)) {
        rb_raise(rb_eRuntimeError, "key lock map is already initialized");
    }
    map->core.compare_keys_by_identity = keys;
    if (rb_typeddata_is_kind_of(self, &unshared_key_lock_type)) {
        atomic_store_explicit(&map->state, KEY_LOCK_INITIALIZED, memory_order_release);
        return self;
    }
    atomic_store_explicit(&map->state, KEY_LOCK_PUBLISHING, memory_order_release);
    return rb_ensure(key_lock_publish, self, key_lock_finish_publication, self);
}

static VALUE
key_lock_yield(VALUE opaque)
{
    (void)opaque;
    return rb_yield_values(0);
}

static VALUE
key_lock_synchronize(VALUE self, VALUE key)
{
    key_lock_map_t *storage = key_lock_get_raw(self);
    int state = atomic_load_explicit(&storage->state, memory_order_acquire);
    bool shared = rb_typeddata_is_kind_of(self, &shared_key_lock_type);
    if (state != KEY_LOCK_INITIALIZED &&
        !(shared && state == KEY_LOCK_PUBLISHING && rb_ractor_shareable_p(self))) {
        rb_raise(rb_eRuntimeError, "uninitialized key lock map");
    }
    rb_need_block();
    if (shared) containers_check_shareable(key);
    map_t *map = &storage->core;
    map_operation_t operation = {
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    operation.hash = map_key_hash(map, key);
    map_lock_for_key(map, key, operation.hash, &operation.execution);
    operation.reservation = map_begin_reservation_locked(
        map, key, operation.hash, &operation.execution
    );
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(key_lock_yield, (VALUE)&operation, map_operation_cleanup, (VALUE)&operation);
}

static VALUE
key_lock_initialize_copy(VALUE self, VALUE other)
{
    (void)self;
    (void)other;
    rb_raise(rb_eTypeError, "key lock maps cannot be copied");
}


void
containers_init_map(VALUE namespace)
{
    cUnsharedKeyLockMap = rb_define_class_under(namespace, "UnsharedKeyLockMap", rb_cObject);
    rb_define_alloc_func(cUnsharedKeyLockMap, unshared_key_lock_allocate);
    rb_define_method(cUnsharedKeyLockMap, "initialize", key_lock_initialize, -1);
    rb_define_method(cUnsharedKeyLockMap, "initialize_copy", key_lock_initialize_copy, 1);
    rb_define_method(cUnsharedKeyLockMap, "synchronize", key_lock_synchronize, 1);

    cSharedKeyLockMap = rb_define_class_under(namespace, "SharedKeyLockMap", rb_cObject);
    rb_define_alloc_func(cSharedKeyLockMap, shared_key_lock_allocate);
    rb_define_method(cSharedKeyLockMap, "initialize", key_lock_initialize, -1);
    rb_define_method(cSharedKeyLockMap, "initialize_copy", key_lock_initialize_copy, 1);
    rb_define_method(cSharedKeyLockMap, "synchronize", key_lock_synchronize, 1);

    cMap = rb_define_class_under(namespace, "Map", rb_cObject);
    rb_define_alloc_func(cMap, map_allocate);
    rb_define_method(cMap, "initialize", map_initialize, -1);
    rb_define_method(cMap, "[]", map_get, 1);
    rb_define_method(cMap, "[]=", map_set, 2);
    rb_define_method(cMap, "fetch", map_fetch, -1);
    rb_define_method(cMap, "get", map_get_with_timeout, -1);
    rb_define_method(cMap, "store", map_store_with_timeout, -1);
    rb_define_method(cMap, "swap", map_swap, -1);
    rb_define_method(cMap, "update", map_update, -1);
    rb_define_method(cMap, "wait_until_changed", map_wait_until_changed, -1);
    rb_define_method(cMap, "wait_until_non_nil", map_wait_until_non_nil, -1);
    rb_define_method(cMap, "store_if_absent", map_store_if_absent, -1);
    rb_define_method(cMap, "key?", map_key_p, 1);
    rb_define_method(cMap, "delete", map_delete, 1);
    rb_define_method(cMap, "clear", map_clear, 0);
    rb_define_method(cMap, "compare_and_set", map_compare_and_set, -1);
    rb_define_method(cMap, "upsert", map_upsert, -1);
    rb_define_method(cMap, "compare_keys_by_identity?", map_compare_keys_by_identity_p, 0);
    rb_define_method(cMap, "compare_values_by_identity?", map_compare_values_by_identity_p, 0);
    rb_define_method(cMap, "getkey", map_getkey, 1);
    rb_define_method(cMap, "size", map_size, 0);
    rb_define_method(cMap, "keys", map_keys, 0);
    rb_define_method(cMap, "each", map_each, 0);
    rb_define_method(cMap, "each_pair", map_each, 0);
    rb_define_method(cMap, "each_key", map_each_key, 0);
    rb_define_method(cMap, "each_value", map_each_value, 0);
}
