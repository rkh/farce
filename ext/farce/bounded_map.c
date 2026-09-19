#include "containers.h"
#include <ruby/atomic.h>
#include <ruby/st.h>

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LRU_INITIAL_CAPACITY ((size_t)8)

enum {
    LRU_UNINITIALIZED = 0,
    LRU_PUBLISHING = 1,
    LRU_INITIALIZED = 2,
};

typedef struct lru_entry lru_entry_t;
typedef struct lfu_entry lfu_entry_t;
typedef struct lfu_bucket lfu_bucket_t;

struct lfu_bucket {
    VALUE frequency;
    lfu_bucket_t *previous;
    lfu_bucket_t *following;
    lru_entry_t *least_recent;
    lru_entry_t *most_recent;
};

struct lru_entry {
    VALUE key;
    VALUE value;
    st_index_t hash;
    size_t slot;
    lru_entry_t *previous;
    lru_entry_t *following;
};

struct lfu_entry {
    lru_entry_t base;
    lfu_bucket_t *bucket;
};

static lfu_entry_t *
lfu_entry_from_base(lru_entry_t *entry)
{
    return (lfu_entry_t *)entry;
}

#define LRU_TOMBSTONE ((lru_entry_t *)(uintptr_t)1)

typedef struct {
    lru_entry_t **slots;
    size_t capacity;
    size_t size;
    size_t tombstones;
    size_t max_size;
    lru_entry_t *least_recent;
    lru_entry_t *most_recent;
    lfu_bucket_t *least_frequency;
    lfu_bucket_t *most_frequency;
    size_t bucket_count;
    VALUE lock;
    bool compare_keys_by_identity;
    bool compare_values_by_identity;
    bool shareable_container;
    bool lfu_policy;
    rb_atomic_t state;
} lru_map_t;

typedef struct {
    VALUE self;
    lru_map_t *map;
    VALUE key;
    VALUE value;
    VALUE result;
    size_t limit;
    bool found;
    bool compare_keys_by_identity;
    bool compare_values_by_identity;
} lru_arguments_t;

static const rb_data_type_t lru_map_type;
static const rb_data_type_t lru_shared_map_type;
static VALUE cLRUMap;
static VALUE cShareableLRUMap;
static VALUE cLFUMap;
static VALUE cShareableLFUMap;

static lru_entry_t **
lru_allocate_slots(size_t capacity)
{
    if (capacity > SIZE_MAX / sizeof(lru_entry_t *)) {
        rb_raise(rb_eRangeError, "bounded map index is too large");
    }
    return ruby_xcalloc(capacity, sizeof(lru_entry_t *));
}

static void
lru_free_entries(lru_entry_t *entry)
{
    while (entry != NULL) {
        lru_entry_t *following = entry->following;
        xfree(entry);
        entry = following;
    }
}

static void
lfu_free_buckets(lfu_bucket_t *bucket)
{
    while (bucket != NULL) {
        lfu_bucket_t *following = bucket->following;
        lru_free_entries(bucket->least_recent);
        xfree(bucket);
        bucket = following;
    }
}

static void
lru_mark(void *opaque)
{
    lru_map_t *map = opaque;
    if (map == NULL) return;

    rb_gc_mark_movable(map->lock);
    if (map->lfu_policy) {
        for (lfu_bucket_t *bucket = map->least_frequency;
             bucket != NULL;
             bucket = bucket->following) {
            rb_gc_mark_movable(bucket->frequency);
            for (lru_entry_t *entry = bucket->least_recent;
                 entry != NULL;
                 entry = entry->following) {
                rb_gc_mark_movable(entry->key);
                rb_gc_mark_movable(entry->value);
            }
        }
    }
    else {
        for (lru_entry_t *entry = map->least_recent;
             entry != NULL;
             entry = entry->following) {
            rb_gc_mark_movable(entry->key);
            rb_gc_mark_movable(entry->value);
        }
    }
}

static void
lru_compact(void *opaque)
{
    lru_map_t *map = opaque;
    if (map == NULL) return;

    map->lock = rb_gc_location(map->lock);
    if (map->lfu_policy) {
        for (lfu_bucket_t *bucket = map->least_frequency;
             bucket != NULL;
             bucket = bucket->following) {
            bucket->frequency = rb_gc_location(bucket->frequency);
            for (lru_entry_t *entry = bucket->least_recent;
                 entry != NULL;
                 entry = entry->following) {
                entry->key = rb_gc_location(entry->key);
                entry->value = rb_gc_location(entry->value);
            }
        }
    }
    else {
        for (lru_entry_t *entry = map->least_recent;
             entry != NULL;
             entry = entry->following) {
            entry->key = rb_gc_location(entry->key);
            entry->value = rb_gc_location(entry->value);
        }
    }
}

static void
lru_free(void *opaque)
{
    lru_map_t *map = opaque;
    if (map == NULL) return;
    if (map->lfu_policy) lfu_free_buckets(map->least_frequency);
    else lru_free_entries(map->least_recent);
    ruby_xfree(map->slots);
    xfree(map);
}

static size_t
lru_memsize(const void *opaque)
{
    const lru_map_t *map = opaque;
    if (map == NULL) return 0;
    return sizeof(*map) +
        map->capacity * sizeof(lru_entry_t *) +
        map->size * (map->lfu_policy ? sizeof(lfu_entry_t) : sizeof(lru_entry_t)) +
        map->bucket_count * sizeof(lfu_bucket_t);
}

static const rb_data_type_t lru_map_type = {
    .wrap_struct_name = "Farce::Internal::BoundedMap",
    .function = {
        .dmark = lru_mark,
        .dfree = lru_free,
        .dsize = lru_memsize,
        .dcompact = lru_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static const rb_data_type_t lru_shared_map_type = {
    .wrap_struct_name = "Farce::Internal::ShareableBoundedMap",
    .function = {
        .dmark = lru_mark,
        .dfree = lru_free,
        .dsize = lru_memsize,
        .dcompact = lru_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
lru_allocate(
    VALUE klass,
    const rb_data_type_t *type,
    bool shareable,
    bool lfu_policy
)
{
    lru_map_t *map;
    VALUE self = TypedData_Make_Struct(klass, lru_map_t, type, map);

    map->slots = NULL;
    map->capacity = 0;
    map->size = 0;
    map->tombstones = 0;
    map->max_size = 0;
    map->least_recent = NULL;
    map->most_recent = NULL;
    map->least_frequency = NULL;
    map->most_frequency = NULL;
    map->bucket_count = 0;
    map->lock = Qnil;
    map->compare_keys_by_identity = false;
    map->compare_values_by_identity = false;
    map->shareable_container = shareable;
    map->lfu_policy = lfu_policy;
    RUBY_ATOMIC_SET(map->state, LRU_UNINITIALIZED);
    RB_OBJ_WRITE(self, &map->lock, containers_lock_new());
    return self;
}

static VALUE
lru_local_allocate(VALUE klass)
{
    return lru_allocate(klass, &lru_map_type, false, false);
}

static VALUE
lru_shared_allocate(VALUE klass)
{
    return lru_allocate(klass, &lru_shared_map_type, true, false);
}

static VALUE
lfu_local_allocate(VALUE klass)
{
    return lru_allocate(klass, &lru_map_type, false, true);
}

static VALUE
lfu_shared_allocate(VALUE klass)
{
    return lru_allocate(klass, &lru_shared_map_type, true, true);
}

static lru_map_t *
lru_get_raw(VALUE self)
{
    lru_map_t *map;
    if (rb_typeddata_is_kind_of(self, &lru_map_type)) {
        TypedData_Get_Struct(self, lru_map_t, &lru_map_type, map);
        return map;
    }
    if (rb_typeddata_is_kind_of(self, &lru_shared_map_type)) {
        TypedData_Get_Struct(self, lru_map_t, &lru_shared_map_type, map);
        return map;
    }
    rb_raise(rb_eTypeError, "wrong bounded map type");
}

static lru_map_t *
lru_get(VALUE self)
{
    lru_map_t *map = lru_get_raw(self);
    rb_atomic_t state = RUBY_ATOMIC_LOAD(map->state);
    if (state == LRU_INITIALIZED) return map;
    if (map->shareable_container &&
        state == LRU_PUBLISHING &&
        rb_ractor_shareable_p(self)) {
        return map;
    }
    else {
        rb_raise(rb_eRuntimeError, "uninitialized bounded map");
    }
}

static void
lru_check_mutable(VALUE self, lru_map_t *map)
{
    if (!map->shareable_container ||
        RUBY_ATOMIC_LOAD(map->state) != LRU_INITIALIZED) {
        rb_check_frozen(self);
    }
}

static size_t
lru_parse_limit(VALUE value, const char *name)
{
    if (!RB_INTEGER_TYPE_P(value)) {
        rb_raise(rb_eTypeError, "%s must be an Integer", name);
    }
    if ((FIXNUM_P(value) && FIX2LONG(value) < 0) ||
        (RB_TYPE_P(value, T_BIGNUM) && RBIGNUM_NEGATIVE_P(value))) {
        rb_raise(rb_eArgError, "%s must be non-negative", name);
    }
    return NUM2SIZET(value);
}

static VALUE
lru_prepare_key(lru_map_t *map, VALUE key)
{
    if (!map->compare_keys_by_identity) {
        key = containers_normalize_string_key(key);
    }
    if (map->shareable_container) containers_check_shareable(key);
    return key;
}

static st_index_t
lru_key_hash(const lru_map_t *map, VALUE key)
{
    if (map->compare_keys_by_identity) {
        return (st_index_t)NUM2ULL(rb_obj_id(key));
    }
    return (st_index_t)NUM2LONG(rb_hash(key));
}

static bool
lru_keys_equal(const lru_map_t *map, VALUE stored, VALUE probe)
{
    if (stored == probe) return true;
    return !map->compare_keys_by_identity && rb_eql(stored, probe);
}

static size_t
lru_find_slot(
    lru_map_t *map,
    VALUE key,
    st_index_t hash,
    bool *found
)
{
    size_t mask = map->capacity - 1;
    size_t first_tombstone = SIZE_MAX;

    for (size_t offset = 0; offset < map->capacity; offset++) {
        size_t index = ((size_t)hash + offset) & mask;
        lru_entry_t *entry = map->slots[index];

        if (entry == NULL) {
            *found = false;
            return first_tombstone == SIZE_MAX ? index : first_tombstone;
        }
        if (entry == LRU_TOMBSTONE) {
            if (first_tombstone == SIZE_MAX) first_tombstone = index;
            continue;
        }
        if (entry->hash == hash && lru_keys_equal(map, entry->key, key)) {
            *found = true;
            return index;
        }
    }

    *found = false;
    return first_tombstone;
}

static size_t
lru_find_empty_slot(const lru_map_t *map, st_index_t hash)
{
    size_t mask = map->capacity - 1;
    size_t first_tombstone = SIZE_MAX;

    for (size_t offset = 0; offset < map->capacity; offset++) {
        size_t index = ((size_t)hash + offset) & mask;
        lru_entry_t *entry = map->slots[index];

        if (entry == NULL) {
            return first_tombstone == SIZE_MAX ? index : first_tombstone;
        }
        if (entry == LRU_TOMBSTONE && first_tombstone == SIZE_MAX) {
            first_tombstone = index;
        }
    }

    if (first_tombstone != SIZE_MAX) return first_tombstone;
    rb_raise(rb_eRuntimeError, "bounded map index has no insertion slot");
}

static void
lru_place_resized_entry(
    lru_entry_t **slots,
    size_t mask,
    lru_entry_t *entry
)
{
    size_t index = (size_t)entry->hash & mask;
    while (slots[index] != NULL) index = (index + 1) & mask;
    slots[index] = entry;
    entry->slot = index;
}

static void
lru_resize(lru_map_t *map, size_t capacity)
{
    lru_entry_t **slots = lru_allocate_slots(capacity);
    size_t mask = capacity - 1;

    if (map->lfu_policy) {
        for (lfu_bucket_t *bucket = map->least_frequency;
             bucket != NULL;
             bucket = bucket->following) {
            for (lru_entry_t *entry = bucket->least_recent;
                 entry != NULL;
                 entry = entry->following) {
                lru_place_resized_entry(slots, mask, entry);
            }
        }
    }
    else {
        for (lru_entry_t *entry = map->least_recent;
             entry != NULL;
             entry = entry->following) {
            lru_place_resized_entry(slots, mask, entry);
        }
    }

    ruby_xfree(map->slots);
    map->slots = slots;
    map->capacity = capacity;
    map->tombstones = 0;
}

static void
lru_prepare_insert(lru_map_t *map)
{
    size_t used = map->size + map->tombstones;
    size_t load_limit = (map->capacity / 10) * 7 +
        (((map->capacity % 10) * 7 + 9) / 10);
    if (used + 1 < load_limit) return;

    if (map->size + 1 < load_limit) {
        lru_resize(map, map->capacity);
        return;
    }
    if (map->capacity > SIZE_MAX / 2) {
        rb_raise(rb_eRangeError, "bounded map index cannot grow further");
    }
    lru_resize(map, map->capacity * 2);
}

static void
lru_unlink(lru_map_t *map, lru_entry_t *entry)
{
    if (entry->previous != NULL) {
        entry->previous->following = entry->following;
    }
    else {
        map->least_recent = entry->following;
    }
    if (entry->following != NULL) {
        entry->following->previous = entry->previous;
    }
    else {
        map->most_recent = entry->previous;
    }
    entry->previous = NULL;
    entry->following = NULL;
}

static void
lru_append(lru_map_t *map, lru_entry_t *entry)
{
    entry->previous = map->most_recent;
    entry->following = NULL;
    if (map->most_recent != NULL) map->most_recent->following = entry;
    else map->least_recent = entry;
    map->most_recent = entry;
}

static void
lru_promote(lru_map_t *map, lru_entry_t *entry)
{
    if (entry == map->most_recent) return;
    lru_unlink(map, entry);
    lru_append(map, entry);
}

static void
lru_remove_entry(lru_map_t *map, lru_entry_t *entry)
{
    lru_unlink(map, entry);
    map->slots[entry->slot] = LRU_TOMBSTONE;
    map->tombstones++;
    map->size--;
    xfree(entry);
}

static void
lru_insert_entry(lru_map_t *map, lru_entry_t *entry, size_t slot)
{
    if (map->slots[slot] == LRU_TOMBSTONE) map->tombstones--;
    map->slots[slot] = entry;
    entry->slot = slot;
    lru_append(map, entry);
    map->size++;
}

static VALUE
lfu_increment_frequency(VALUE frequency)
{
    if (FIXNUM_P(frequency)) {
        long value = FIX2LONG(frequency);
        return value < FIXNUM_MAX ? LONG2FIX(value + 1) : LONG2NUM(value + 1);
    }
    return rb_big_plus(frequency, INT2FIX(1));
}

static bool
lfu_frequencies_equal(VALUE left, VALUE right)
{
    if (left == right) return true;
    if (!RB_TYPE_P(left, T_BIGNUM) || !RB_TYPE_P(right, T_BIGNUM)) {
        return false;
    }
    return rb_big_cmp(left, right) == INT2FIX(0);
}

static lfu_bucket_t *
lfu_allocate_bucket(VALUE self, VALUE frequency)
{
    lfu_bucket_t *bucket = ALLOC(lfu_bucket_t);
    bucket->frequency = Qnil;
    bucket->previous = NULL;
    bucket->following = NULL;
    bucket->least_recent = NULL;
    bucket->most_recent = NULL;
    RB_OBJ_WRITE(self, &bucket->frequency, frequency);
    return bucket;
}

static void
lfu_link_bucket_after(
    lru_map_t *map,
    lfu_bucket_t *previous,
    lfu_bucket_t *bucket
)
{
    bucket->previous = previous;
    if (previous == NULL) {
        bucket->following = map->least_frequency;
        map->least_frequency = bucket;
    }
    else {
        bucket->following = previous->following;
        previous->following = bucket;
    }
    if (bucket->following != NULL) bucket->following->previous = bucket;
    else map->most_frequency = bucket;
    map->bucket_count++;
}

static void
lfu_remove_bucket(lru_map_t *map, lfu_bucket_t *bucket)
{
    if (bucket->previous != NULL) {
        bucket->previous->following = bucket->following;
    }
    else {
        map->least_frequency = bucket->following;
    }
    if (bucket->following != NULL) {
        bucket->following->previous = bucket->previous;
    }
    else {
        map->most_frequency = bucket->previous;
    }
    map->bucket_count--;
    xfree(bucket);
}

static void
lfu_unlink_entry(lfu_bucket_t *bucket, lru_entry_t *entry)
{
    if (entry->previous != NULL) {
        entry->previous->following = entry->following;
    }
    else {
        bucket->least_recent = entry->following;
    }
    if (entry->following != NULL) {
        entry->following->previous = entry->previous;
    }
    else {
        bucket->most_recent = entry->previous;
    }
    entry->previous = NULL;
    entry->following = NULL;
}

static void
lfu_append_entry(lfu_bucket_t *bucket, lru_entry_t *entry)
{
    lfu_entry_from_base(entry)->bucket = bucket;
    entry->previous = bucket->most_recent;
    entry->following = NULL;
    if (bucket->most_recent != NULL) bucket->most_recent->following = entry;
    else bucket->least_recent = entry;
    bucket->most_recent = entry;
}

static void
lfu_promote(VALUE self, lru_map_t *map, lru_entry_t *entry)
{
    lfu_bucket_t *current = lfu_entry_from_base(entry)->bucket;
    lfu_bucket_t *following = current->following;
    VALUE frequency = lfu_increment_frequency(current->frequency);

    if (following != NULL &&
        lfu_frequencies_equal(following->frequency, frequency)) {
        lfu_unlink_entry(current, entry);
        lfu_append_entry(following, entry);
        if (current->least_recent == NULL) lfu_remove_bucket(map, current);
        return;
    }

    if (current->least_recent == current->most_recent) {
        RB_OBJ_WRITE(self, &current->frequency, frequency);
        return;
    }

    lfu_bucket_t *destination = lfu_allocate_bucket(self, frequency);
    lfu_link_bucket_after(map, current, destination);
    lfu_unlink_entry(current, entry);
    lfu_append_entry(destination, entry);
}

static void
lfu_remove_entry(lru_map_t *map, lru_entry_t *entry)
{
    lfu_bucket_t *bucket = lfu_entry_from_base(entry)->bucket;
    lfu_unlink_entry(bucket, entry);
    map->slots[entry->slot] = LRU_TOMBSTONE;
    map->tombstones++;
    map->size--;
    xfree(entry);
    if (bucket->least_recent == NULL) lfu_remove_bucket(map, bucket);
}

static void
bounded_remove_entry(lru_map_t *map, lru_entry_t *entry)
{
    if (map->lfu_policy) lfu_remove_entry(map, entry);
    else lru_remove_entry(map, entry);
}

static lru_entry_t *
bounded_victim(lru_map_t *map)
{
    return map->lfu_policy
        ? map->least_frequency->least_recent
        : map->least_recent;
}

static VALUE
lru_call_locked(
    lru_map_t *map,
    containers_lock_operation_t operation,
    lru_arguments_t *arguments
)
{
    return containers_lock_synchronize_call(map->lock, operation, (VALUE)arguments);
}

static VALUE
lru_store_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key;
    st_index_t hash;
    size_t slot;
    bool found;

    lru_check_mutable(arguments->self, map);
    key = lru_prepare_key(map, arguments->key);
    if (map->shareable_container) containers_check_shareable(arguments->value);
    hash = lru_key_hash(map, key);
    if (map->max_size == 0) {
        lru_check_mutable(arguments->self, map);
        return arguments->value;
    }
    slot = lru_find_slot(map, key, hash, &found);
    lru_check_mutable(arguments->self, map);

    if (found) {
        lru_entry_t *entry = map->slots[slot];
        RB_OBJ_WRITE(arguments->self, &entry->value, arguments->value);
        lru_promote(map, entry);
        return arguments->value;
    }

    lru_prepare_insert(map);
    slot = lru_find_empty_slot(map, hash);

    lru_entry_t *entry = ALLOC(lru_entry_t);
    entry->key = Qnil;
    entry->value = Qnil;
    entry->hash = hash;
    entry->slot = 0;
    entry->previous = NULL;
    entry->following = NULL;
    RB_OBJ_WRITE(arguments->self, &entry->key, key);
    RB_OBJ_WRITE(arguments->self, &entry->value, arguments->value);

    lru_entry_t *victim = map->size >= map->max_size
        ? map->least_recent
        : NULL;
    lru_insert_entry(map, entry, slot);
    if (victim != NULL) bounded_remove_entry(map, victim);
    return arguments->value;
}

static VALUE
lru_store(VALUE self, VALUE key, VALUE value)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {
        .self = self,
        .map = map,
        .key = key,
        .value = value,
    };
    return lru_call_locked(map, lru_store_body, &arguments);
}

typedef struct {
    VALUE self;
    VALUE frequency;
    lfu_bucket_t *bucket;
} lfu_bucket_allocation_t;

static VALUE
lfu_allocate_bucket_body(VALUE opaque)
{
    lfu_bucket_allocation_t *allocation =
        (lfu_bucket_allocation_t *)opaque;
    allocation->bucket = lfu_allocate_bucket(
        allocation->self,
        allocation->frequency
    );
    return Qnil;
}

static lfu_bucket_t *
lfu_allocate_bucket_after_entry(
    VALUE self,
    VALUE frequency,
    lru_entry_t *entry
)
{
    lfu_bucket_allocation_t allocation = {
        .self = self,
        .frequency = frequency,
        .bucket = NULL,
    };
    int state = 0;

    (void)rb_protect(lfu_allocate_bucket_body, (VALUE)&allocation, &state);
    if (state != 0) {
        xfree(entry);
        rb_jump_tag(state);
    }
    return allocation.bucket;
}

static VALUE
lfu_initial_frequency(void)
{
#ifdef FARCE_TEST_LFU_OVERFLOW
    return LONG2NUM(FIXNUM_MAX - 1);
#else
    return INT2FIX(1);
#endif
}

static VALUE
lfu_store_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key;
    st_index_t hash;
    size_t slot;
    bool found;

    lru_check_mutable(arguments->self, map);
    key = lru_prepare_key(map, arguments->key);
    if (map->shareable_container) containers_check_shareable(arguments->value);
    hash = lru_key_hash(map, key);
    if (map->max_size == 0) {
        lru_check_mutable(arguments->self, map);
        return arguments->value;
    }
    slot = lru_find_slot(map, key, hash, &found);
    lru_check_mutable(arguments->self, map);

    if (found) {
        lru_entry_t *entry = map->slots[slot];
        lfu_promote(arguments->self, map, entry);
        RB_OBJ_WRITE(arguments->self, &entry->value, arguments->value);
        return arguments->value;
    }

    lru_prepare_insert(map);
    slot = lru_find_empty_slot(map, hash);
    VALUE frequency = lfu_initial_frequency();
    lfu_bucket_t *bucket = map->least_frequency;
    bool needs_bucket = bucket == NULL ||
        !lfu_frequencies_equal(bucket->frequency, frequency);
    lfu_entry_t *allocated_entry = ALLOC(lfu_entry_t);
    lru_entry_t *entry = &allocated_entry->base;
    lfu_bucket_t *new_bucket = needs_bucket
        ? lfu_allocate_bucket_after_entry(
            arguments->self,
            frequency,
            entry
        )
        : NULL;

    entry->key = Qnil;
    entry->value = Qnil;
    entry->hash = hash;
    entry->slot = slot;
    entry->previous = NULL;
    entry->following = NULL;
    allocated_entry->bucket = NULL;
    RB_OBJ_WRITE(arguments->self, &entry->key, key);
    RB_OBJ_WRITE(arguments->self, &entry->value, arguments->value);

    lru_entry_t *victim = map->size >= map->max_size
        ? bounded_victim(map)
        : NULL;
    if (new_bucket != NULL) {
        lfu_link_bucket_after(map, NULL, new_bucket);
        bucket = new_bucket;
    }
    if (map->slots[slot] == LRU_TOMBSTONE) map->tombstones--;
    map->slots[slot] = entry;
    map->size++;
    lfu_append_entry(bucket, entry);
    if (victim != NULL) lfu_remove_entry(map, victim);
    return arguments->value;
}

static VALUE
lfu_store(VALUE self, VALUE key, VALUE value)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {
        .self = self,
        .map = map,
        .key = key,
        .value = value,
    };
    return lru_call_locked(map, lfu_store_body, &arguments);
}

static VALUE
lru_lookup_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key = lru_prepare_key(map, arguments->key);
    st_index_t hash = lru_key_hash(map, key);
    bool found;
    size_t slot = lru_find_slot(map, key, hash, &found);

    arguments->found = found;
    if (!found) return Qnil;
    lru_check_mutable(arguments->self, map);
    lru_entry_t *entry = map->slots[slot];
    lru_promote(map, entry);
    return entry->value;
}

static VALUE
lru_aref(VALUE self, VALUE key)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map, .key = key};
    return lru_call_locked(map, lru_lookup_body, &arguments);
}

static VALUE
lfu_lookup_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key = lru_prepare_key(map, arguments->key);
    st_index_t hash = lru_key_hash(map, key);
    bool found;
    size_t slot = lru_find_slot(map, key, hash, &found);

    arguments->found = found;
    if (!found) return Qnil;
    lru_check_mutable(arguments->self, map);
    lru_entry_t *entry = map->slots[slot];
    lfu_promote(arguments->self, map, entry);
    return entry->value;
}

static VALUE
lfu_aref(VALUE self, VALUE key)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map, .key = key};
    return lru_call_locked(map, lfu_lookup_body, &arguments);
}

static VALUE
lru_fetch(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE default_value = Qnil;
    bool default_given;
    bool block_given;
    lru_map_t *map;
    lru_arguments_t arguments;
    VALUE result;

    rb_scan_args(argc, argv, "11", &key, &default_value);
    default_given = argc == 2;
    block_given = rb_block_given_p();
    if (default_given && block_given) rb_warn("block supersedes default value argument");

    map = lru_get(self);
    arguments = (lru_arguments_t){.self = self, .map = map, .key = key};
    result = lru_call_locked(map, lru_lookup_body, &arguments);
    if (arguments.found) return result;
    if (block_given) return rb_yield(key);
    if (default_given) return default_value;
    containers_raise_key_error(self, key);
    return Qnil;
}

static VALUE
lfu_fetch(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE default_value = Qnil;
    bool default_given;
    bool block_given;
    lru_map_t *map;
    lru_arguments_t arguments;
    VALUE result;

    rb_scan_args(argc, argv, "11", &key, &default_value);
    default_given = argc == 2;
    block_given = rb_block_given_p();
    if (default_given && block_given) {
        rb_warn("block supersedes default value argument");
    }

    map = lru_get(self);
    arguments = (lru_arguments_t){.self = self, .map = map, .key = key};
    result = lru_call_locked(map, lfu_lookup_body, &arguments);
    if (arguments.found) return result;
    if (block_given) return rb_yield(key);
    if (default_given) return default_value;
    containers_raise_key_error(self, key);
    return Qnil;
}

static VALUE
lru_observe_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key = lru_prepare_key(map, arguments->key);
    st_index_t hash = lru_key_hash(map, key);
    bool found;
    size_t slot = lru_find_slot(map, key, hash, &found);

    arguments->found = found;
    arguments->result = found ? map->slots[slot]->key : Qnil;
    return arguments->result;
}

static VALUE
lru_preflight_key_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key = lru_prepare_key(map, arguments->key);
    st_index_t hash = lru_key_hash(map, key);
    bool found;

    (void)lru_find_slot(map, key, hash, &found);
    return key;
}

static VALUE
lru_preflight_key(VALUE self, VALUE key)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map, .key = key};
    return lru_call_locked(map, lru_preflight_key_body, &arguments);
}

static VALUE
lru_key_p(VALUE self, VALUE key)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map, .key = key};
    (void)lru_call_locked(map, lru_observe_body, &arguments);
    return arguments.found ? Qtrue : Qfalse;
}

static VALUE
lru_getkey(VALUE self, VALUE key)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map, .key = key};
    return lru_call_locked(map, lru_observe_body, &arguments);
}

static VALUE
lru_delete_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    VALUE key;
    st_index_t hash;
    bool found;
    size_t slot;

    lru_check_mutable(arguments->self, map);
    key = lru_prepare_key(map, arguments->key);
    hash = lru_key_hash(map, key);
    slot = lru_find_slot(map, key, hash, &found);
    lru_check_mutable(arguments->self, map);
    if (!found) return Qnil;

    lru_entry_t *entry = map->slots[slot];
    VALUE result = entry->value;
    bounded_remove_entry(map, entry);
    return result;
}

static VALUE
lru_delete(VALUE self, VALUE key)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map, .key = key};
    return lru_call_locked(map, lru_delete_body, &arguments);
}

static VALUE
lru_clear_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    lru_entry_t **slots;

    lru_check_mutable(arguments->self, map);
    slots = lru_allocate_slots(LRU_INITIAL_CAPACITY);
    if (map->lfu_policy) lfu_free_buckets(map->least_frequency);
    else lru_free_entries(map->least_recent);
    ruby_xfree(map->slots);
    map->slots = slots;
    map->capacity = LRU_INITIAL_CAPACITY;
    map->size = 0;
    map->tombstones = 0;
    map->least_recent = NULL;
    map->most_recent = NULL;
    map->least_frequency = NULL;
    map->most_frequency = NULL;
    map->bucket_count = 0;
    return arguments->self;
}

static VALUE
lru_clear(VALUE self)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    return lru_call_locked(map, lru_clear_body, &arguments);
}

static VALUE
lru_size_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    return SIZET2NUM(arguments->map->size);
}

static VALUE
lru_size(VALUE self)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    return lru_call_locked(map, lru_size_body, &arguments);
}

static VALUE
lru_empty_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    return arguments->map->size == 0 ? Qtrue : Qfalse;
}

static VALUE
lru_empty_p(VALUE self)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    return lru_call_locked(map, lru_empty_body, &arguments);
}

static VALUE
lru_max_size_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    return SIZET2NUM(arguments->map->max_size);
}

static VALUE
lru_max_size(VALUE self)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    return lru_call_locked(map, lru_max_size_body, &arguments);
}

static void
lru_prune_to(lru_map_t *map, size_t target)
{
    while (map->size > target) {
        bounded_remove_entry(map, bounded_victim(map));
    }
}

static VALUE
lru_resize_limit_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_check_mutable(arguments->self, arguments->map);
    lru_prune_to(arguments->map, arguments->limit);
    arguments->map->max_size = arguments->limit;
    return arguments->result;
}

static VALUE
lru_set_max_size(VALUE self, VALUE limit)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {
        .self = self,
        .map = map,
        .limit = lru_parse_limit(limit, "max_size"),
    };
    arguments.result = SIZET2NUM(arguments.limit);
    return lru_call_locked(map, lru_resize_limit_body, &arguments);
}

static VALUE
lru_prune_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_check_mutable(arguments->self, arguments->map);
    size_t original = arguments->map->size;
    size_t removed = original > arguments->limit
        ? original - arguments->limit
        : 0;
    VALUE result = SIZET2NUM(removed);
    lru_prune_to(arguments->map, arguments->limit);
    return result;
}

static VALUE
lru_prune(int argc, VALUE *argv, VALUE self)
{
    VALUE keywords = Qnil;
    VALUE keyword_values[1];
    ID keyword_ids[] = {rb_intern("to")};

    rb_scan_args(argc, argv, "0:", &keywords);
    rb_get_kwargs(keywords, keyword_ids, 1, 0, keyword_values);
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {
        .self = self,
        .map = map,
        .limit = lru_parse_limit(keyword_values[0], "to"),
    };
    return lru_call_locked(map, lru_prune_body, &arguments);
}

static VALUE
lru_shift_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    lru_check_mutable(arguments->self, map);
    if (map->size == 0) return Qnil;

    lru_entry_t *entry = bounded_victim(map);
    VALUE pair = rb_assoc_new(entry->key, entry->value);
    bounded_remove_entry(map, entry);
    return pair;
}

static VALUE
lru_shift(VALUE self)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    return lru_call_locked(map, lru_shift_body, &arguments);
}

static VALUE
lru_snapshot_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    if (map->size > (size_t)LONG_MAX / 2) {
        rb_raise(rb_eRangeError, "bounded map is too large to enumerate");
    }

    VALUE entries = rb_ary_new_capa((long)(map->size * 2));
    if (map->lfu_policy) {
        for (lfu_bucket_t *bucket = map->least_frequency;
             bucket != NULL;
             bucket = bucket->following) {
            for (lru_entry_t *entry = bucket->least_recent;
                 entry != NULL;
                 entry = entry->following) {
                rb_ary_push(entries, entry->key);
                rb_ary_push(entries, entry->value);
            }
        }
    }
    else {
        for (lru_entry_t *entry = map->least_recent;
             entry != NULL;
             entry = entry->following) {
            rb_ary_push(entries, entry->key);
            rb_ary_push(entries, entry->value);
        }
    }
    return entries;
}

static VALUE
lru_enumerator_size(VALUE self, VALUE arguments, VALUE enumerator)
{
    (void)arguments;
    (void)enumerator;
    return lru_size(self);
}

static VALUE
lru_each(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, lru_enumerator_size);
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    VALUE entries = lru_call_locked(map, lru_snapshot_body, &arguments);
    long length = RARRAY_LEN(entries);

    for (long index = 0; index < length; index += 2) {
        rb_yield(rb_assoc_new(
            RARRAY_AREF(entries, index),
            RARRAY_AREF(entries, index + 1)
        ));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
lru_each_key(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, lru_enumerator_size);
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    VALUE entries = lru_call_locked(map, lru_snapshot_body, &arguments);
    long length = RARRAY_LEN(entries);

    for (long index = 0; index < length; index += 2) {
        rb_yield(RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
lru_each_value(VALUE self)
{
    RETURN_SIZED_ENUMERATOR(self, 0, NULL, lru_enumerator_size);
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    VALUE entries = lru_call_locked(map, lru_snapshot_body, &arguments);
    long length = RARRAY_LEN(entries);

    for (long index = 1; index < length; index += 2) {
        rb_yield(RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
lru_keys(VALUE self)
{
    lru_map_t *map = lru_get(self);
    lru_arguments_t arguments = {.self = self, .map = map};
    VALUE entries = lru_call_locked(map, lru_snapshot_body, &arguments);
    long length = RARRAY_LEN(entries);
    VALUE keys = rb_ary_new_capa(length / 2);

    for (long index = 0; index < length; index += 2) {
        rb_ary_push(keys, RARRAY_AREF(entries, index));
    }
    RB_GC_GUARD(entries);
    rb_obj_freeze(keys);
    return keys;
}

static VALUE
lru_compare_keys_by_identity_p(VALUE self)
{
    return lru_get(self)->compare_keys_by_identity ? Qtrue : Qfalse;
}

static VALUE
lru_compare_values_by_identity_p(VALUE self)
{
    return lru_get(self)->compare_values_by_identity ? Qtrue : Qfalse;
}

static int
lru_initialize_entry(VALUE key, VALUE value, VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    arguments->key = key;
    arguments->value = value;
    if (arguments->map->lfu_policy) {
        (void)lfu_store_body((VALUE)arguments);
    }
    else {
        (void)lru_store_body((VALUE)arguments);
    }
    return ST_CONTINUE;
}

static void
lru_check_initializable(VALUE self, lru_map_t *map)
{
    if (RUBY_ATOMIC_LOAD(map->state) == LRU_INITIALIZED) {
        rb_raise(rb_eRuntimeError, "bounded map is already initialized");
    }
    rb_check_frozen(self);
    if (RUBY_ATOMIC_LOAD(map->state) != LRU_UNINITIALIZED) {
        rb_raise(rb_eRuntimeError, "bounded map is already initialized");
    }
}

static VALUE
lru_make_shareable(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    containers_finish_initialization(arguments->self);
    return arguments->self;
}

static VALUE
lru_finish_publication(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    rb_atomic_t state = rb_ractor_shareable_p(arguments->self)
        ? LRU_INITIALIZED
        : LRU_UNINITIALIZED;

    RUBY_ATOMIC_SET(arguments->map->state, state);
    return Qnil;
}

static VALUE
lru_initialize_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *map = arguments->map;
    lru_entry_t **slots;

    lru_check_initializable(arguments->self, map);
    slots = lru_allocate_slots(LRU_INITIAL_CAPACITY);
    if (map->lfu_policy) lfu_free_buckets(map->least_frequency);
    else lru_free_entries(map->least_recent);
    ruby_xfree(map->slots);
    map->slots = slots;
    map->capacity = LRU_INITIAL_CAPACITY;
    map->size = 0;
    map->tombstones = 0;
    map->max_size = arguments->limit;
    map->least_recent = NULL;
    map->most_recent = NULL;
    map->least_frequency = NULL;
    map->most_frequency = NULL;
    map->bucket_count = 0;
    map->compare_keys_by_identity = arguments->compare_keys_by_identity;
    map->compare_values_by_identity = arguments->compare_values_by_identity;

    if (!NIL_P(arguments->value)) {
        rb_hash_foreach(arguments->value, lru_initialize_entry, opaque);
    }

    if (!map->shareable_container) {
        RUBY_ATOMIC_SET(map->state, LRU_INITIALIZED);
        return arguments->self;
    }

    RUBY_ATOMIC_SET(map->state, LRU_PUBLISHING);
    return rb_ensure(
        lru_make_shareable,
        opaque,
        lru_finish_publication,
        opaque
    );
}

static VALUE
lru_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE entries = Qnil;
    VALUE keywords = Qnil;
    VALUE keyword_values[4] = {Qundef, Qundef, Qundef, Qundef};
    ID keyword_ids[] = {
        rb_intern("max_size"),
        rb_intern("compare_by_identity"),
        rb_intern("compare_keys_by_identity"),
        rb_intern("compare_values_by_identity"),
    };
    lru_map_t *map = lru_get_raw(self);

    rb_scan_args(argc, argv, "01:", &entries, &keywords);
    lru_check_initializable(self, map);
    rb_get_kwargs(keywords, keyword_ids, 1, 3, keyword_values);

    bool common = keyword_values[1] == Qundef
        ? false
        : containers_strict_bool(keyword_values[1], "compare_by_identity");
    bool compare_keys_by_identity = keyword_values[2] == Qundef
        ? common
        : containers_strict_bool(keyword_values[2], "compare_keys_by_identity");
    bool compare_values_by_identity = keyword_values[3] == Qundef
        ? common
        : containers_strict_bool(keyword_values[3], "compare_values_by_identity");
    size_t max_size = lru_parse_limit(keyword_values[0], "max_size");

    if (!NIL_P(entries)) {
        entries = rb_check_hash_type(entries);
        if (NIL_P(entries)) {
            rb_raise(rb_eTypeError, "entries must be a Hash or respond to #to_hash");
        }
    }
    lru_check_initializable(self, map);

    lru_arguments_t arguments = {
        .self = self,
        .map = map,
        .value = entries,
        .limit = max_size,
        .compare_keys_by_identity = compare_keys_by_identity,
        .compare_values_by_identity = compare_values_by_identity,
    };
    return lru_call_locked(map, lru_initialize_body, &arguments);
}

static VALUE
lru_copy_body(VALUE opaque)
{
    lru_arguments_t *arguments = (lru_arguments_t *)opaque;
    lru_map_t *source = lru_get(arguments->value);
    lru_map_t *copy = arguments->map;
    VALUE self = arguments->self;

    lru_check_initializable(self, copy);
    lru_entry_t **slots = lru_allocate_slots(source->capacity);
    if (copy->lfu_policy) lfu_free_buckets(copy->least_frequency);
    else lru_free_entries(copy->least_recent);
    ruby_xfree(copy->slots);
    copy->slots = slots;
    copy->capacity = source->capacity;
    copy->size = 0;
    copy->tombstones = 0;
    copy->max_size = source->max_size;
    copy->least_recent = NULL;
    copy->most_recent = NULL;
    copy->least_frequency = NULL;
    copy->most_frequency = NULL;
    copy->bucket_count = 0;
    copy->compare_keys_by_identity = source->compare_keys_by_identity;
    copy->compare_values_by_identity = source->compare_values_by_identity;

    if (source->lfu_policy) {
        for (lfu_bucket_t *source_bucket = source->least_frequency;
             source_bucket != NULL;
             source_bucket = source_bucket->following) {
            lfu_bucket_t *bucket = lfu_allocate_bucket(self, source_bucket->frequency);
            lfu_link_bucket_after(copy, copy->most_frequency, bucket);
            for (lru_entry_t *source_entry = source_bucket->least_recent;
                 source_entry != NULL;
                 source_entry = source_entry->following) {
                lfu_entry_t *entry = ALLOC(lfu_entry_t);
                entry->base.key = Qnil;
                entry->base.value = Qnil;
                entry->base.hash = source_entry->hash;
                entry->base.previous = NULL;
                entry->base.following = NULL;
                entry->bucket = NULL;
                RB_OBJ_WRITE(self, &entry->base.key, source_entry->key);
                RB_OBJ_WRITE(self, &entry->base.value, source_entry->value);
                lru_place_resized_entry(copy->slots, copy->capacity - 1, &entry->base);
                lfu_append_entry(bucket, &entry->base);
                copy->size++;
            }
        }
    }
    else {
        for (lru_entry_t *source_entry = source->least_recent;
             source_entry != NULL;
             source_entry = source_entry->following) {
            lru_entry_t *entry = ALLOC(lru_entry_t);
            entry->key = Qnil;
            entry->value = Qnil;
            entry->hash = source_entry->hash;
            entry->previous = NULL;
            entry->following = NULL;
            RB_OBJ_WRITE(self, &entry->key, source_entry->key);
            RB_OBJ_WRITE(self, &entry->value, source_entry->value);
            lru_place_resized_entry(copy->slots, copy->capacity - 1, entry);
            lru_append(copy, entry);
            copy->size++;
        }
    }

    if (!copy->shareable_container) {
        RUBY_ATOMIC_SET(copy->state, LRU_INITIALIZED);
        return self;
    }

    RUBY_ATOMIC_SET(copy->state, LRU_PUBLISHING);
    return rb_ensure(lru_make_shareable, opaque, lru_finish_publication, opaque);
}

static VALUE
lru_initialize_copy(VALUE self, VALUE other)
{
    lru_map_t *source = lru_get(other);
    lru_map_t *copy = lru_get_raw(self);
    lru_arguments_t arguments = {
        .self = self,
        .map = copy,
        .value = other,
    };

    lru_check_initializable(self, copy);
    if (source->lfu_policy != copy->lfu_policy ||
        source->shareable_container != copy->shareable_container) {
        rb_raise(rb_eTypeError, "incompatible bounded map copy");
    }
    return lru_call_locked(source, lru_copy_body, &arguments);
}

static void
lru_define_methods(VALUE klass, bool lfu_policy)
{
    rb_define_method(klass, "initialize", lru_initialize, -1);
    rb_define_method(klass, "initialize_copy", lru_initialize_copy, 1);
    rb_define_method(klass, "[]", lfu_policy ? lfu_aref : lru_aref, 1);
    rb_define_method(klass, "[]=", lfu_policy ? lfu_store : lru_store, 2);
    rb_define_method(klass, "fetch", lfu_policy ? lfu_fetch : lru_fetch, -1);
    rb_define_method(klass, "prepare_key", lru_preflight_key, 1);
    rb_define_method(klass, "key?", lru_key_p, 1);
    rb_define_method(klass, "getkey", lru_getkey, 1);
    rb_define_method(klass, "delete", lru_delete, 1);
    rb_define_method(klass, "clear", lru_clear, 0);
    rb_define_method(klass, "max_size", lru_max_size, 0);
    rb_define_method(klass, "max_size=", lru_set_max_size, 1);
    rb_define_method(klass, "prune", lru_prune, -1);
    rb_define_method(klass, "shift", lru_shift, 0);
    rb_define_method(klass, "size", lru_size, 0);
    rb_define_method(klass, "length", lru_size, 0);
    rb_define_method(klass, "empty?", lru_empty_p, 0);
    rb_define_method(klass, "compare_keys_by_identity?", lru_compare_keys_by_identity_p, 0);
    rb_define_method(klass, "compare_values_by_identity?", lru_compare_values_by_identity_p, 0);
    rb_define_method(klass, "each", lru_each, 0);
    rb_define_method(klass, "each_pair", lru_each, 0);
    rb_define_method(klass, "each_key", lru_each_key, 0);
    rb_define_method(klass, "each_value", lru_each_value, 0);
    rb_define_method(klass, "keys", lru_keys, 0);
}

void
containers_init_lru_maps(VALUE internal)
{
    cLRUMap = rb_define_class_under(internal, "LRUMap", rb_cObject);
    rb_define_alloc_func(cLRUMap, lru_local_allocate);
    lru_define_methods(cLRUMap, false);

    cShareableLRUMap = rb_define_class_under(
        internal,
        "ShareableLRUMap",
        rb_cObject
    );
    rb_define_alloc_func(cShareableLRUMap, lru_shared_allocate);
    lru_define_methods(cShareableLRUMap, false);

    cLFUMap = rb_define_class_under(internal, "LFUMap", rb_cObject);
    rb_define_alloc_func(cLFUMap, lfu_local_allocate);
    lru_define_methods(cLFUMap, true);

    cShareableLFUMap = rb_define_class_under(
        internal,
        "ShareableLFUMap",
        rb_cObject
    );
    rb_define_alloc_func(cShareableLFUMap, lfu_shared_allocate);
    lru_define_methods(cShareableLFUMap, true);
}
