#include "containers.h"
#include "transaction.h"
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
static VALUE cUnsharedMap;
static VALUE map_keep;
static VALUE map_delete_token;
static VALUE cUnsharedKeyLockMap;
static VALUE cSharedKeyLockMap;
static VALUE cStrictMapFacade;
static VALUE cUnsharedMapFacade;
static VALUE cModeMapFacade;
static VALUE cMapEnvelope;
static VALUE map_nil_value;
static VALUE eIsolationError;
static const rb_data_type_t map_type;
static ID id_map;
static ID id_unwrap_value;
static ID id_wrap_value;


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
    uint64_t iteration_epoch;
    map_waiter_t *waiters;
    bool compare_keys_by_identity;
    bool compare_values_by_identity;
    bool shareable;
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
map_validate_references(VALUE self)
{
    map_t *map;
    TypedData_Get_Struct(self, map_t, &map_type, map);
    for (size_t index = 0; index < map->capacity; index++) {
        if (map->slots[index].state != MAP_OCCUPIED) continue;
        containers_check_shareable(map->slots[index].key);
        containers_check_shareable(map->slots[index].value);
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

static const rb_data_type_t unshared_map_type = {
    .wrap_struct_name = "Farce::Internal::UnsharedMap",
    .function = {
        .dmark = map_mark,
        .dfree = map_free,
        .dsize = map_memsize,
        .dcompact = map_compact,
    },
    .parent = &map_type,
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
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

static void
shared_key_lock_mark(void *pointer)
{
    /* Reservations are transient synchronization state, not part of the
     * shareability graph. Their keys are validated before insertion, while
     * their Fiber and Thread owners are intentionally unshareable. Excluding
     * them from non-GC reachability also keeps concurrent Ractor shareability
     * traversals from walking a reservation that another Ractor can remove. */
    if (rb_during_gc()) map_mark(pointer);
}

static const rb_data_type_t shared_key_lock_type = {
    .wrap_struct_name = "Farce::Internal::SharedKeyLockMap",
    .function = {
        .dmark = shared_key_lock_mark,
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
    map->iteration_epoch = 0;
    map->waiters = NULL;
    map->compare_keys_by_identity = false;
    map->compare_values_by_identity = false;
    map->shareable = false;
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
    map->shareable = true;
    return object;
}

static VALUE
unshared_map_allocate(VALUE klass)
{
    map_t *map;
    VALUE object = TypedData_Make_Struct(klass, map_t, &unshared_map_type, map);
    map_initialize_storage(map);
    VALUE guard = rb_path2class("Farce::Internal::Unshareable");
    rb_funcall(guard, rb_intern("pin_to_current_ractor"), 1, object);
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
    if (left == right) return true;
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

/* Resolve lookups that cannot call user equality code. This lets the common
 * same-object hit avoid capturing Fiber and Thread state. Return false when
 * an equal-hash key requires the full callback-safe comparison protocol. */
static bool
map_find_slot_without_equality(
    map_t *map,
    VALUE key,
    st_index_t hash,
    size_t *index,
    bool *found
)
{
    size_t mask = map->capacity - 1;
    size_t first_tombstone = SIZE_MAX;

    for (size_t offset = 0; offset < map->capacity; offset++) {
        size_t candidate = ((size_t)hash + offset) & mask;
        map_slot_t *slot = &map->slots[candidate];

        if (slot->state == MAP_EMPTY) {
            *index = first_tombstone == SIZE_MAX ? candidate : first_tombstone;
            *found = false;
            return true;
        }
        if (slot->state == MAP_TOMBSTONE) {
            if (first_tombstone == SIZE_MAX) first_tombstone = candidate;
            continue;
        }
        if (slot->hash != hash) continue;
        if (slot->key == key) {
            *index = candidate;
            *found = true;
            return true;
        }
        if (map->compare_keys_by_identity) continue;
        /* CRuby's rb_eql uses built-in comparison for exact Strings. Keep
         * subclasses and singleton classes on the callback-safe path. */
        if (CLASS_OF(slot->key) == rb_cString && RB_TYPE_P(key, T_STRING)) {
            if (RTEST(rb_str_equal(slot->key, key))) {
                *index = candidate;
                *found = true;
                return true;
            }
            continue;
        }
        return false;
    }

    *index = first_tombstone;
    *found = false;
    return true;
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
    map->iteration_epoch++;
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
    VALUE self,
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
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
    map_slot_t *slot = &map->slots[index];
    if (!found) {
        if (slot->state == MAP_TOMBSTONE) map->tombstones--;
        slot->key = key;
        slot->hash = hash;
        slot->state = MAP_OCCUPIED;
        map->size++;
        map->iteration_epoch++;
    }
    slot->value = value;
    map_notify_waiters_locked(map);
    return value;
}

static VALUE
map_normalize_key(map_t *map, VALUE key)
{
    if (!map->compare_keys_by_identity && RB_TYPE_P(key, T_STRING) && !RB_OBJ_FROZEN(key)) {
        key = containers_normalize_string_key(key);
    }
    return key;
}

static VALUE
map_prepare_key(map_t *map, VALUE key)
{
    key = map_normalize_key(map, key);
    if (map->shareable) containers_check_shareable(key);
    return key;
}

static void
map_check_value(map_t *map, VALUE value)
{
    if (map->shareable) containers_check_shareable(value);
}

typedef struct {
    VALUE self;
    map_t *map;
    map_execution_context_t execution;
} map_init_context_t;

static int
map_initialize_entry(VALUE key, VALUE value, VALUE opaque)
{
    map_init_context_t *context = (map_init_context_t *)opaque;
    key = map_prepare_key(context->map, key);
    map_check_value(context->map, value);
    st_index_t hash = map_key_hash(context->map, key);
    map_lock_state(context->map, &context->execution);
    map_store_locked(context->self, context->map, key, value, hash, &context->execution);
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
            .self = self,
            .map = map,
            .execution = map_current_execution_context(),
        };
        rb_hash_foreach(mapping, map_initialize_entry, (VALUE)&context);
    }
    map->initialized = true;
    if (map->shareable) containers_publish_native_with_references(self, map_validate_references);
    return self;
}

static VALUE
map_get(VALUE self, VALUE key)
{
    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    size_t index;

    pthread_mutex_lock(&map->lock);
    if (!map->comparing && map_find_slot_without_equality(map, key, hash, &index, &found)) {
        if (found) result = map->slots[index].value;
        pthread_mutex_unlock(&map->lock);
        return result;
    }
    pthread_mutex_unlock(&map->lock);

    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    index = map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);
    return result;
}

static VALUE
map_check_mutation(VALUE self)
{
    rb_check_frozen(self);
    return self;
}

static VALUE
map_prepare_mutation_key(VALUE self, VALUE key)
{
    rb_check_frozen(self);
    map_t *map = get_map(self);
    key = map_normalize_key(map, key);
    if (map->shareable && !rb_ractor_shareable_p(key)) {
        rb_raise(eIsolationError, "key must be Ractor-shareable");
    }
    return key;
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

    VALUE original_key = key;
    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    st_index_t hash = map_key_hash(map, key);
    bool found;
    VALUE result = Qnil;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_state(map, &execution);
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (found) result = map->slots[index].value;
    pthread_mutex_unlock(&map->lock);

    if (found) return result;
    if (block_given) return rb_yield(original_key);
    if (default_given) return default_value;
    containers_raise_key_error(self, original_key);
    return Qnil;
}

static VALUE
map_set(VALUE self, VALUE key, VALUE value)
{
    rb_check_frozen(self);
    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_check_value(map, value);
    st_index_t hash = map_key_hash(map, key);
    rb_check_frozen(self);

    /* Replacing an existing entry needs neither allocation nor execution
     * context when no callback or atomic update owns the map. Keep the
     * callback/reservation path below for all other cases. */
    bool found;
    size_t index;
    pthread_mutex_lock(&map->lock);
    if (!map->comparing && !map->reservations &&
        map_find_slot_without_equality(map, key, hash, &index, &found) && found) {
        if (RB_OBJ_FROZEN(self)) {
            pthread_mutex_unlock(&map->lock);
            rb_check_frozen(self);
        }
        map->slots[index].value = value;
        map_notify_waiters_locked(map);
        pthread_mutex_unlock(&map->lock);
        return value;
    }
    pthread_mutex_unlock(&map->lock);

    map_execution_context_t execution = map_current_execution_context();
    map_lock_for_key(map, key, hash, &execution);
    map_store_locked(self, map, key, value, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static bool
map_is_backend(VALUE backend, const rb_data_type_t *type)
{
    return RB_TYPE_P(backend, T_DATA) && RTYPEDDATA_P(backend) &&
        RTYPEDDATA_TYPE(backend) == type;
}

/* The public direct maps retain Ruby fallbacks for subclasses and normalized
 * adapters. Ordinary access reaches the native backend without Ruby forwarding. */
static const rb_data_type_t *
map_facade_type(VALUE self)
{
    VALUE klass = rb_obj_class(self);
    if (klass == cStrictMapFacade) return &map_type;
    if (klass == cUnsharedMapFacade) return &unshared_map_type;
    return NULL;
}

static VALUE
plain_map_get(VALUE self, VALUE key)
{
    const rb_data_type_t *type = map_facade_type(self);
    if (!type) return rb_call_super(1, &key);
    VALUE backend = rb_ivar_get(self, id_map);
    if (map_is_backend(backend, type)) return map_get(backend, key);
    return rb_funcall(backend, rb_intern("[]"), 1, key);
}

static VALUE
plain_map_set(VALUE self, VALUE key, VALUE value)
{
    const rb_data_type_t *type = map_facade_type(self);
    if (!type) {
        VALUE arguments[] = {key, value};
        return rb_call_super(2, arguments);
    }
    VALUE backend = rb_ivar_get(self, id_map);
    if (map_is_backend(backend, type)) return map_set(backend, key, value);
    return rb_funcall(backend, rb_intern("[]="), 2, key, value);
}

/* Values already shareable need no mode conversion. Envelopes, normalized
 * backends, and subclasses retain the Ruby hooks that implement their policy. */
static VALUE
mode_map_get(VALUE self, VALUE key)
{
    if (rb_obj_class(self) != cModeMapFacade) return rb_call_super(1, &key);
    VALUE backend = rb_ivar_get(self, id_map);
    if (!map_is_backend(backend, &map_type)) return rb_call_super(1, &key);
    VALUE result = map_get(backend, key);
    if (result == map_nil_value) return Qnil;
    if (rb_obj_is_kind_of(result, cMapEnvelope)) {
        return rb_funcall(self, id_unwrap_value, 1, result);
    }
    return result;
}

static VALUE
mode_map_set(VALUE self, VALUE key, VALUE value)
{
    VALUE backend = rb_ivar_get(self, id_map);
    if (rb_obj_class(self) != cModeMapFacade || !map_is_backend(backend, &map_type)) {
        VALUE arguments[] = {key, value};
        return rb_call_super(2, arguments);
    }
    /* Preserve the key-specific error and validate before any value transfer. */
    key = map_prepare_mutation_key(backend, key);
    /* These are the positive fast checks from rb_ractor_shareable_p. A missing
     * flag means unknown, so let wrap_value classify and transfer it once.
     * Preclassifying here would traverse partly frozen graphs twice. */
    VALUE stored = RB_SPECIAL_CONST_P(value) || RB_OBJ_SHAREABLE_P(value)
        ? (NIL_P(value) ? map_nil_value : value)
        : rb_funcall(self, id_wrap_value, 1, value);
    map_set(backend, key, stored);
    return value;
}

static VALUE
map_prepare_access(VALUE namespace, VALUE klass, VALUE kind)
{
    (void)namespace;
    Check_Type(klass, T_CLASS);
    Check_Type(kind, T_SYMBOL);
    ID policy_id = SYM2ID(kind);
    if (policy_id == rb_intern("modes")) {
        cModeMapFacade = klass;
        cMapEnvelope = rb_path2class("Farce::Envelope");
        VALUE policy = rb_path2class("Farce::Internal::MapValueModes");
        map_nil_value = rb_const_get(policy, rb_intern("NIL_VALUE"));
        rb_define_method(klass, "[]", mode_map_get, 1);
        rb_define_method(klass, "[]=", mode_map_set, 2);
    }
    else {
        if (policy_id == rb_intern("strict")) cStrictMapFacade = klass;
        else if (policy_id == rb_intern("unshared")) cUnsharedMapFacade = klass;
        else rb_raise(rb_eArgError, "unknown native map policy");
        rb_define_method(klass, "[]", plain_map_get, 1);
        rb_define_method(klass, "[]=", plain_map_set, 2);
    }
    return klass;
}

static VALUE
map_key_p(VALUE self, VALUE key)
{
    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
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
    key = map_prepare_key(map, key);
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
    rb_check_frozen(self);
    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    st_index_t hash = map_key_hash(map, key);
    rb_check_frozen(self);
    bool found;
    VALUE result = Qnil;
    map_execution_context_t execution = map_current_execution_context();
    map_lock_for_key(map, key, hash, &execution);
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
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
    rb_check_frozen(self);
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
    map->iteration_epoch++;
    map->size = 0;
    map->tombstones = 0;
    map_notify_waiters_locked(map);
    pthread_mutex_unlock(&map->lock);
    return self;
}

typedef struct {
    VALUE self;
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
    bool present;
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
    map_check_value(operation->map, result);
    rb_check_frozen(operation->self);
    map_lock_state(operation->map, &operation->execution);
    bool stored = !operation->reservation->invalidated;
    if (stored) {
        map_store_locked(
            operation->self,
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
    rb_check_frozen(self);
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_operation_t operation = {
        .self = self,
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    rb_need_block();
    operation.hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_timeout_t timeout = map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qnil;
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
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
    rb_check_frozen(operation->self);

    map_lock_state(operation->map, &operation->execution);
    bool replaced = matches && !operation->reservation->invalidated;
    if (replaced) {
        map_store_locked(
            operation->self,
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
    rb_check_frozen(self);
    VALUE key;
    VALUE expected;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "3:", &key, &expected, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_operation_t operation = {
        .self = self,
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .argument = expected,
        .replacement = replacement,
        .identity = map->compare_values_by_identity,
        .complete = false,
    };
    map_check_value(map, expected);
    map_check_value(map, replacement);
    operation.hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_timeout_t timeout = map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qfalse;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
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

/* Decisions are interpreted before value validation. KEEP never writes storage. */
static VALUE
map_modify_body(VALUE opaque)
{
    map_operation_t *operation = (map_operation_t *)opaque;
    VALUE value = rb_yield_values(2, operation->present ? Qtrue : Qfalse, operation->current);
    bool remove = value == map_delete_token;
    bool store = !remove && value != map_keep;
    if (store) map_check_value(operation->map, value);
    rb_check_frozen(operation->self);
    map_lock_state(operation->map, &operation->execution);
    bool changed = false;
    if (store && !operation->reservation->invalidated) {
        map_store_locked(operation->self, operation->map, operation->key, value,
            operation->hash, &operation->execution);
        changed = true;
    } else if (remove && !operation->reservation->invalidated) {
        bool found;
        size_t index = map_find_slot(operation->map, operation->key,
            operation->hash, &found, &operation->execution);
        if (RB_OBJ_FROZEN(operation->self)) {
            pthread_mutex_unlock(&operation->map->lock);
            rb_check_frozen(operation->self);
        }
        if (found) {
            map_slot_t *slot = &operation->map->slots[index];
            slot->key = Qnil;
            slot->value = Qnil;
            slot->state = MAP_TOMBSTONE;
            operation->map->size--;
            operation->map->tombstones++;
            map_notify_waiters_locked(operation->map);
            changed = true;
        }
    }
    operation->complete = true;
    map_finish_reservation_locked(operation->map, operation->reservation);
    pthread_mutex_unlock(&operation->map->lock);
    return changed ? Qtrue : Qfalse;
}

static VALUE
map_modify(VALUE self, VALUE key)
{
    rb_check_frozen(self);
    rb_need_block();
    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_operation_t operation = {
        .self = self,
        .execution = map_current_execution_context(),
        .map = map,
        .key = key,
        .complete = false,
    };
    operation.hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_lock_for_key(map, key, operation.hash, &operation.execution);
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
    operation.present = found;
    operation.current = found ? map->slots[index].value : Qnil;
    operation.reservation = map_begin_reservation_locked(map, key, operation.hash, &operation.execution);
    pthread_mutex_unlock(&map->lock);
    return rb_ensure(map_modify_body, (VALUE)&operation, map_operation_cleanup, (VALUE)&operation);
}

static VALUE
map_upsert_body(VALUE opaque)
{
    map_operation_t *operation = (map_operation_t *)opaque;
    VALUE result = rb_yield(operation->current);
    map_check_value(operation->map, result);
    rb_check_frozen(operation->self);
    map_lock_state(operation->map, &operation->execution);
    bool stored = !operation->reservation->invalidated;
    if (stored) {
        map_store_locked(
            operation->self,
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
    rb_check_frozen(self);
    VALUE key;
    VALUE initial;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &initial, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_operation_t operation = {
        .self = self,
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    map_check_value(map, initial);
    rb_need_block();
    operation.hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_timeout_t timeout = map_parse_timeout(
        keyword_values[0] == Qundef ? Qnil : keyword_values[0]
    );

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qnil;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
    if (!found) {
        map_store_locked(self, map, key, initial, operation.hash, &operation.execution);
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

/* A bounded live traversal. No native lock is held across a Ruby yield.
 * Insertions, rehashing and clearing invalidate the cursor. Deletions and
 * value replacement are permitted while the table layout stays unchanged. */
static VALUE
map_each_live(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, map_enumerator_size);
    map_t *map = get_map(self);
    map_execution_context_t execution = map_current_execution_context();
    size_t cursor = 0;
    uint64_t epoch = 0;
    bool started = false;
    const long batch_slots = 64;
    VALUE batch = rb_ary_new_capa(batch_slots);
    rb_ary_resize(batch, batch_slots);

    for (;;) {
        VALUE *storage = RARRAY_PTR(batch);
        for (long index = 0; index < batch_slots; index++) {
            RB_OBJ_WRITE(batch, &storage[index], Qnil);
        }
        map_lock_state(map, &execution);
        if (started && epoch != map->iteration_epoch) {
            pthread_mutex_unlock(&map->lock);
            rb_raise(rb_eRuntimeError, "map structurally changed during live iteration");
        }
        epoch = map->iteration_epoch;
        started = true;
        long length = 0;
        while (cursor < map->capacity && length < batch_slots) {
            map_slot_t *slot = &map->slots[cursor++];
            if (slot->state != MAP_OCCUPIED) continue;
            RB_OBJ_WRITE(batch, &storage[length++], slot->key);
            RB_OBJ_WRITE(batch, &storage[length++], slot->value);
        }
        pthread_mutex_unlock(&map->lock);
        if (length == 0) break;
        for (long index = 0; index < length; index += 2) {
            rb_yield(rb_assoc_new(RARRAY_AREF(batch, index), RARRAY_AREF(batch, index + 1)));
        }
    }
    RB_GC_GUARD(batch);
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
    key = map_prepare_key(map, key);
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
    rb_check_frozen(self);
    VALUE key;
    VALUE value;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &value, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_check_value(map, value);
    st_index_t hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);
    map_execution_context_t execution = map_current_execution_context();
    if (!map_lock_for_key_with_timeout(map, key, hash, &timeout, &execution)) {
        return map_timeout_result();
    }
    map_store_locked(self, map, key, value, hash, &execution);
    pthread_mutex_unlock(&map->lock);
    return value;
}

static VALUE
map_swap(int argc, VALUE *argv, VALUE self)
{
    rb_check_frozen(self);
    VALUE key;
    VALUE replacement;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "2:", &key, &replacement, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_check_value(map, replacement);
    st_index_t hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);
    map_execution_context_t execution = map_current_execution_context();
    if (!map_lock_for_key_with_timeout(map, key, hash, &timeout, &execution)) {
        return map_timeout_result();
    }

    bool found;
    size_t index = map_find_slot(map, key, hash, &found, &execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
    VALUE previous = found ? map->slots[index].value : Qnil;
    map_store_locked(self, map, key, replacement, hash, &execution);
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
    key = map_prepare_key(map, key);
    if (!non_nil) map_check_value(map, expected);
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
    rb_check_frozen(self);
    VALUE key;
    VALUE keywords = Qnil;
    VALUE keyword_values[1] = {Qundef};
    ID keyword_ids[] = {rb_intern("timeout")};
    rb_scan_args(argc, argv, "1:", &key, &keywords);
    if (!NIL_P(keywords)) rb_get_kwargs(keywords, keyword_ids, 0, 1, keyword_values);

    map_t *map = get_map(self);
    key = map_prepare_key(map, key);
    map_operation_t operation = {
        .self = self,
        .map = map,
        .execution = map_current_execution_context(),
        .key = key,
        .complete = false,
    };
    rb_need_block();
    operation.hash = map_key_hash(map, key);
    rb_check_frozen(self);
    map_timeout_t timeout = map_parse_timeout(keyword_values[0] == Qundef ? Qnil : keyword_values[0]);

    if (!map_lock_for_key_with_timeout(
        map, key, operation.hash, &timeout, &operation.execution
    )) return Qnil;
    bool found;
    size_t index = map_find_slot(map, key, operation.hash, &found, &operation.execution);
    if (RB_OBJ_FROZEN(self)) {
        pthread_mutex_unlock(&map->lock);
        rb_check_frozen(self);
    }
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

static void
shared_key_lock_validate_references(VALUE self)
{
    key_lock_map_t *storage;
    TypedData_Get_Struct(self, key_lock_map_t, &shared_key_lock_type, storage);
    map_t *map = &storage->core;
    for (size_t index = 0; index < map->capacity; index++) {
        if (map->slots[index].state != MAP_OCCUPIED) continue;
        containers_check_shareable(map->slots[index].key);
        containers_check_shareable(map->slots[index].value);
    }
    for (map_reservation_t *reservation = map->reservations; reservation; reservation = reservation->next) {
        containers_check_shareable(reservation->key);
    }
}

static VALUE
key_lock_publish(VALUE self)
{
    return containers_publish_native_with_references(self, shared_key_lock_validate_references);
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

static bool
map_transaction_valid(farce_transaction_entry_t *entry)
{
    map_t *map = entry->source_data;
    return map->generation == entry->version && !map->comparing && !map->reservations;
}

static void
map_transaction_apply(farce_transaction_entry_t *entry)
{
    map_t *map = entry->source_data;
    map_t *copy = entry->working_data;
    map_slot_t *slots = map->slots;
    size_t capacity = map->capacity, size = map->size, tombstones = map->tombstones;
    map->slots = copy->slots;
    map->capacity = copy->capacity;
    map->size = copy->size;
    map->tombstones = copy->tombstones;
    map->iteration_epoch++;
    copy->slots = slots;
    copy->capacity = capacity;
    copy->size = size;
    copy->tombstones = tombstones;
}

static void
map_transaction_notify(farce_transaction_entry_t *entry)
{
    map_notify_waiters_locked(entry->source_data);
}

static const farce_transaction_ops_t map_transaction_ops = {
    map_transaction_valid, map_transaction_apply, map_transaction_notify,
};

static VALUE
map_transaction_snapshot(VALUE self)
{
    map_t *source = get_map(self);
    VALUE working = source->shareable ? map_allocate(cMap) : unshared_map_allocate(cUnsharedMap);
    map_t *copy;
    TypedData_Get_Struct(working, map_t, &map_type, copy);
    farce_transaction_entry_t *entry;
    VALUE result = farce_transaction_entry_new(
        self, working, source, copy, &source->lock, &map_transaction_ops, &entry
    );
    pthread_mutex_lock(&source->lock);
    copy->slots = malloc(source->capacity * sizeof(map_slot_t));
    if (!copy->slots) {
        pthread_mutex_unlock(&source->lock);
        rb_memerror();
    }
    memcpy(copy->slots, source->slots, source->capacity * sizeof(map_slot_t));
    copy->capacity = source->capacity;
    copy->size = source->size;
    copy->tombstones = source->tombstones;
    copy->compare_keys_by_identity = source->compare_keys_by_identity;
    copy->compare_values_by_identity = source->compare_values_by_identity;
    copy->initialized = true;
    entry->version = source->generation;
    pthread_mutex_unlock(&source->lock);
    return result;
}

static void
map_define_methods(VALUE klass)
{
    rb_define_method(klass, "initialize", map_initialize, -1);
    rb_define_method(klass, "[]", map_get, 1);
    rb_define_method(klass, "[]=", map_set, 2);
    rb_define_method(klass, "check_mutation", map_check_mutation, 0);
    rb_define_method(klass, "prepare_mutation_key", map_prepare_mutation_key, 1);
    rb_define_method(klass, "fetch", map_fetch, -1);
    rb_define_method(klass, "get", map_get_with_timeout, -1);
    rb_define_method(klass, "store", map_store_with_timeout, -1);
    rb_define_method(klass, "swap", map_swap, -1);
    rb_define_method(klass, "update", map_update, -1);
    rb_define_method(klass, "modify", map_modify, 1);
    rb_define_method(klass, "wait_until_changed", map_wait_until_changed, -1);
    rb_define_method(klass, "wait_until_non_nil", map_wait_until_non_nil, -1);
    rb_define_method(klass, "store_if_absent", map_store_if_absent, -1);
    rb_define_method(klass, "key?", map_key_p, 1);
    rb_define_method(klass, "delete", map_delete, 1);
    rb_define_method(klass, "clear", map_clear, 0);
    rb_define_method(klass, "transaction_snapshot", map_transaction_snapshot, 0);
    rb_define_method(klass, "compare_and_set", map_compare_and_set, -1);
    rb_define_method(klass, "upsert", map_upsert, -1);
    rb_define_method(klass, "compare_keys_by_identity?", map_compare_keys_by_identity_p, 0);
    rb_define_method(klass, "compare_values_by_identity?", map_compare_values_by_identity_p, 0);
    rb_define_method(klass, "getkey", map_getkey, 1);
    rb_define_method(klass, "size", map_size, 0);
    rb_define_method(klass, "keys", map_keys, 0);
    rb_define_method(klass, "each", map_each, 0);
    rb_define_method(klass, "each_live", map_each_live, 0);
    rb_define_method(klass, "each_pair", map_each, 0);
    rb_define_method(klass, "each_key", map_each_key, 0);
    rb_define_method(klass, "each_value", map_each_value, 0);
}


void
containers_init_map(VALUE namespace)
{
    rb_global_variable(&cStrictMapFacade);
    rb_global_variable(&cUnsharedMapFacade);
    id_map = rb_intern("@map");
    id_unwrap_value = rb_intern("unwrap_value");
    id_wrap_value = rb_intern("wrap_value");
    rb_global_variable(&cModeMapFacade);
    rb_global_variable(&cMapEnvelope);
    rb_global_variable(&map_nil_value);
    eIsolationError = rb_const_get(rb_cRactor, rb_intern("IsolationError"));
    map_keep = rb_const_get(namespace, rb_intern("MAP_KEEP"));
    map_delete_token = rb_const_get(namespace, rb_intern("MAP_DELETE"));
    rb_global_variable(&map_keep);
    rb_global_variable(&map_delete_token);
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
    rb_define_method(cSharedKeyLockMap, "freeze", containers_raise_unfreezable, 0);

    cMap = rb_define_class_under(namespace, "Map", rb_cObject);
    rb_define_alloc_func(cMap, map_allocate);
    map_define_methods(cMap);

    cUnsharedMap = rb_define_class_under(namespace, "UnsharedMap", rb_cObject);
    rb_define_alloc_func(cUnsharedMap, unshared_map_allocate);
    map_define_methods(cUnsharedMap);
    rb_define_singleton_method(
        namespace, "prepare_map_access", map_prepare_access, 2
    );
}
