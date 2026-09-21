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
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

/*
 * A clean-room implementation of the conventional red-black-tree algorithms.
 *
 * This file intentionally shares no implementation with the Kazlib-backed
 * priority queue. The generic link layer knows nothing about Ruby objects;
 * each map node stores one key/value pair.
 */

typedef enum {
    TC_RED = 0,
    TC_BLACK = 1
} tc_color;

enum {
    TC_MAP_UNINITIALIZED = 0,
    TC_MAP_PUBLISHING = 1,
    TC_MAP_PUBLISHED = 2,
    TC_MAP_INITIALIZED = 3,
};

static inline bool
tc_core_map_publication_busy(rb_atomic_t state)
{
    return state == TC_MAP_PUBLISHING || state == TC_MAP_PUBLISHED;
}

typedef struct tc_link {
    struct tc_link *left;
    struct tc_link *right;
    struct tc_link *parent;
    tc_color color;
} tc_link;

static ID tc_id_compare;
static VALUE tc_eIsolationError;

static inline tc_color
tc_link_color(const tc_link *link)
{
    return link == NULL ? TC_BLACK : link->color;
}

static inline void
tc_link_set_color(tc_link *link, tc_color color)
{
    if (link != NULL) link->color = color;
}

static tc_link *
tc_link_minimum(tc_link *link)
{
    if (link == NULL) return NULL;
    while (link->left != NULL) link = link->left;
    return link;
}

static tc_link *
tc_link_maximum(tc_link *link)
{
    if (link == NULL) return NULL;
    while (link->right != NULL) link = link->right;
    return link;
}

static void
tc_rotate_left(tc_link **root, tc_link *upper)
{
    tc_link *lower = upper->right;

    upper->right = lower->left;
    if (lower->left != NULL) lower->left->parent = upper;

    lower->parent = upper->parent;
    if (upper->parent == NULL) {
        *root = lower;
    }
    else if (upper == upper->parent->left) {
        upper->parent->left = lower;
    }
    else {
        upper->parent->right = lower;
    }

    lower->left = upper;
    upper->parent = lower;
}

static void
tc_rotate_right(tc_link **root, tc_link *upper)
{
    tc_link *lower = upper->left;

    upper->left = lower->right;
    if (lower->right != NULL) lower->right->parent = upper;

    lower->parent = upper->parent;
    if (upper->parent == NULL) {
        *root = lower;
    }
    else if (upper == upper->parent->right) {
        upper->parent->right = lower;
    }
    else {
        upper->parent->left = lower;
    }

    lower->right = upper;
    upper->parent = lower;
}

static void
tc_insert_fix(tc_link **root, tc_link *node)
{
    while (node->parent != NULL && node->parent->color == TC_RED) {
        tc_link *parent = node->parent;
        tc_link *grandparent = parent->parent;

        if (parent == grandparent->left) {
            tc_link *uncle = grandparent->right;
            if (tc_link_color(uncle) == TC_RED) {
                parent->color = TC_BLACK;
                uncle->color = TC_BLACK;
                grandparent->color = TC_RED;
                node = grandparent;
            }
            else {
                if (node == parent->right) {
                    node = parent;
                    tc_rotate_left(root, node);
                    parent = node->parent;
                    grandparent = parent->parent;
                }
                parent->color = TC_BLACK;
                grandparent->color = TC_RED;
                tc_rotate_right(root, grandparent);
            }
        }
        else {
            tc_link *uncle = grandparent->left;
            if (tc_link_color(uncle) == TC_RED) {
                parent->color = TC_BLACK;
                uncle->color = TC_BLACK;
                grandparent->color = TC_RED;
                node = grandparent;
            }
            else {
                if (node == parent->left) {
                    node = parent;
                    tc_rotate_right(root, node);
                    parent = node->parent;
                    grandparent = parent->parent;
                }
                parent->color = TC_BLACK;
                grandparent->color = TC_RED;
                tc_rotate_left(root, grandparent);
            }
        }
    }

    (*root)->color = TC_BLACK;
}

static void
tc_insert_link(tc_link **root, tc_link *parent, tc_link *node, bool insert_left)
{
    node->left = NULL;
    node->right = NULL;
    node->parent = parent;
    node->color = TC_RED;

    if (parent == NULL) {
        *root = node;
    }
    else if (insert_left) {
        parent->left = node;
    }
    else {
        parent->right = node;
    }

    tc_insert_fix(root, node);
}

static void
tc_transplant(tc_link **root, tc_link *old_link, tc_link *new_link)
{
    if (old_link->parent == NULL) {
        *root = new_link;
    }
    else if (old_link == old_link->parent->left) {
        old_link->parent->left = new_link;
    }
    else {
        old_link->parent->right = new_link;
    }

    if (new_link != NULL) new_link->parent = old_link->parent;
}

/* `node` may be NULL. `parent` is its logical parent in that case. */
static void
tc_delete_fix(tc_link **root, tc_link *node, tc_link *parent)
{
    while (node != *root && tc_link_color(node) == TC_BLACK) {
        tc_link *sibling;

        if (parent == NULL) break;

        if (node == parent->left) {
            sibling = parent->right;

            if (tc_link_color(sibling) == TC_RED) {
                sibling->color = TC_BLACK;
                parent->color = TC_RED;
                tc_rotate_left(root, parent);
                sibling = parent->right;
            }

            if (sibling == NULL) {
                node = parent;
                parent = node->parent;
                continue;
            }

            if (tc_link_color(sibling->left) == TC_BLACK &&
                tc_link_color(sibling->right) == TC_BLACK) {
                sibling->color = TC_RED;
                node = parent;
                parent = node->parent;
            }
            else {
                if (tc_link_color(sibling->right) == TC_BLACK) {
                    tc_link_set_color(sibling->left, TC_BLACK);
                    sibling->color = TC_RED;
                    tc_rotate_right(root, sibling);
                    sibling = parent->right;
                }

                sibling->color = parent->color;
                parent->color = TC_BLACK;
                tc_link_set_color(sibling->right, TC_BLACK);
                tc_rotate_left(root, parent);
                node = *root;
                parent = NULL;
            }
        }
        else {
            sibling = parent->left;

            if (tc_link_color(sibling) == TC_RED) {
                sibling->color = TC_BLACK;
                parent->color = TC_RED;
                tc_rotate_right(root, parent);
                sibling = parent->left;
            }

            if (sibling == NULL) {
                node = parent;
                parent = node->parent;
                continue;
            }

            if (tc_link_color(sibling->right) == TC_BLACK &&
                tc_link_color(sibling->left) == TC_BLACK) {
                sibling->color = TC_RED;
                node = parent;
                parent = node->parent;
            }
            else {
                if (tc_link_color(sibling->left) == TC_BLACK) {
                    tc_link_set_color(sibling->right, TC_BLACK);
                    sibling->color = TC_RED;
                    tc_rotate_left(root, sibling);
                    sibling = parent->left;
                }

                sibling->color = parent->color;
                parent->color = TC_BLACK;
                tc_link_set_color(sibling->left, TC_BLACK);
                tc_rotate_right(root, parent);
                node = *root;
                parent = NULL;
            }
        }
    }

    tc_link_set_color(node, TC_BLACK);
}

static void
tc_remove_link(tc_link **root, tc_link *removed)
{
    tc_link *moved = removed;
    tc_link *replacement;
    tc_link *replacement_parent;
    tc_color original_color = moved->color;

    if (removed->left == NULL) {
        replacement = removed->right;
        replacement_parent = removed->parent;
        tc_transplant(root, removed, removed->right);
    }
    else if (removed->right == NULL) {
        replacement = removed->left;
        replacement_parent = removed->parent;
        tc_transplant(root, removed, removed->left);
    }
    else {
        moved = tc_link_minimum(removed->right);
        original_color = moved->color;
        replacement = moved->right;

        if (moved->parent == removed) {
            replacement_parent = moved;
            if (replacement != NULL) replacement->parent = moved;
        }
        else {
            replacement_parent = moved->parent;
            tc_transplant(root, moved, moved->right);
            moved->right = removed->right;
            moved->right->parent = moved;
        }

        tc_transplant(root, removed, moved);
        moved->left = removed->left;
        moved->left->parent = moved;
        moved->color = removed->color;
    }

    if (original_color == TC_BLACK) {
        tc_delete_fix(root, replacement, replacement_parent);
    }
}

typedef struct {
    unsigned int *guard;
    VALUE left;
    VALUE right;
} tc_call_args;

static VALUE
tc_compare_body(VALUE opaque)
{
    tc_call_args *args = (tc_call_args *)opaque;
    VALUE result = rb_funcall(args->left, tc_id_compare, 1, args->right);
    return INT2NUM(rb_cmpint(result, args->left, args->right));
}

static VALUE
tc_call_ensure(VALUE opaque)
{
    tc_call_args *args = (tc_call_args *)opaque;
    (*args->guard)--;
    return Qnil;
}

static int
tc_compare_keys(unsigned int *guard, VALUE left, VALUE right)
{
    tc_call_args args = {guard, left, right};
    VALUE result;

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

        if (!isnan(left_value) && !isnan(right_value)) {
            if (left_value < right_value) return -1;
            if (left_value > right_value) return 1;
            return 0;
        }
    }

    (*guard)++;
    result = rb_ensure(tc_compare_body, (VALUE)&args, tc_call_ensure, (VALUE)&args);
    return NUM2INT(result);
}

typedef struct tc_map_node {
    tc_link link;
    VALUE key;
    VALUE value;
} tc_map_node;

typedef struct {
    tc_link *root;
    size_t size;
    unsigned int guard;
} tc_map;

#define TC_MAP_NODE(link_pointer) ((tc_map_node *)(link_pointer))

static void
tc_map_store_node_value(VALUE self, tc_map_node *node, VALUE value)
{
    RB_OBJ_WRITE(self, &node->value, value);
}

static void
tc_map_mark_node(tc_link *link)
{
    tc_map_node *node;

    if (link == NULL) return;
    node = TC_MAP_NODE(link);
    rb_gc_mark_movable(node->key);
    rb_gc_mark_movable(node->value);
    tc_map_mark_node(link->left);
    tc_map_mark_node(link->right);
}

static void
tc_map_validate_shareable_node(tc_link *link)
{
    if (link == NULL) return;
    tc_map_node *node = TC_MAP_NODE(link);
    containers_check_shareable(node->key);
    containers_check_shareable(node->value);
    tc_map_validate_shareable_node(link->left);
    tc_map_validate_shareable_node(link->right);
}

static void
tc_map_compact_node(tc_link *link)
{
    tc_map_node *node;

    if (link == NULL) return;
    node = TC_MAP_NODE(link);
    node->key = rb_gc_location(node->key);
    node->value = rb_gc_location(node->value);
    tc_map_compact_node(link->left);
    tc_map_compact_node(link->right);
}

static void
tc_map_free_node(tc_link *link)
{
    tc_map_node *node;

    if (link == NULL) return;
    tc_map_free_node(link->left);
    tc_map_free_node(link->right);
    node = TC_MAP_NODE(link);
    xfree(node);
}

static tc_map_node *
tc_map_find(tc_map *map, VALUE key, tc_map_node **parent_out, bool *left_out)
{
    tc_link *link = map->root;
    tc_map_node *parent = NULL;
    bool insert_left = false;

    while (link != NULL) {
        tc_map_node *node = TC_MAP_NODE(link);
        int comparison = tc_compare_keys(&map->guard, key, node->key);

        if (comparison == 0) {
            if (parent_out != NULL) *parent_out = parent;
            if (left_out != NULL) *left_out = insert_left;
            return node;
        }

        parent = node;
        insert_left = comparison < 0;
        link = insert_left ? link->left : link->right;
    }

    if (parent_out != NULL) *parent_out = parent;
    if (left_out != NULL) *left_out = insert_left;
    return NULL;
}

static VALUE
tc_map_store_unlocked(VALUE self, tc_map *map, VALUE key, VALUE value,
                      bool honor_freeze)
{
    tc_map_node *parent;
    tc_map_node *node;
    bool insert_left;

    node = tc_map_find(map, key, &parent, &insert_left);
    /* A comparator is arbitrary Ruby code and may freeze the receiver.  The
     * pre-operation check is therefore insufficient: honor local-container
     * freeze semantics again after the last callback and before committing. */
    if (honor_freeze) rb_check_frozen(self);
    if (node != NULL) {
        tc_map_store_node_value(self, node, value);
        return value;
    }

    node = ALLOC(tc_map_node);
    node->key = Qnil;
    node->value = Qnil;
    RB_OBJ_WRITE(self, &node->key, key);
    RB_OBJ_WRITE(self, &node->value, value);
    tc_insert_link(&map->root, parent == NULL ? NULL : &parent->link,
                   &node->link, insert_left);
    map->size++;
    return value;
}
/* ------------------------------------------------------------------------- */
/* UnsafeTreeMap / TreeMap / ShareableTreeMap                                */

/* The three maps deliberately share the exact same node layout and red-black
 * tree operations. The policy bits decide whether a public operation takes
 * the mutex and whether values and the container must be Ractor-shareable.
 * Keys are always shareable so comparator callbacks cannot capture an object
 * graph that is unsafe to use as ordered state. */
typedef struct tc_core_map_waiter tc_core_map_waiter;

struct tc_core_map_waiter {
    int read_fd;
    int write_fd;
    bool notified;
    tc_core_map_waiter *next;
};

typedef struct {
    tc_map map; /* Must stay first: the generic map algorithm operates on it. */
    pthread_mutex_t lock;
    VALUE owner_fiber;
    VALUE owner_ruby_thread;
    tc_core_map_waiter *waiters;
    tc_core_map_waiter *last_waiter;
    /* Omitted from dmark so the publisher itself is not part of the
     * recursively shareable graph. */
    VALUE publication_owner_fiber;
    VALUE publication_owner_ruby_thread;
    bool mutex_initialized;
    bool synchronized;
    bool shareable_container;
    rb_atomic_t publication_state;
} tc_core_map;

static const rb_data_type_t tc_unsafe_map_type;
static const rb_data_type_t tc_map_type;
static const rb_data_type_t tc_shared_map_type;

static void tc_core_map_wait_for_publication(VALUE self, tc_core_map *core);

static void
tc_core_map_mark(void *opaque)
{
    tc_core_map *core = opaque;
    if (core == NULL) return;
    tc_map_mark_node(core->map.root);
    rb_gc_mark_movable(core->owner_fiber);
    rb_gc_mark_movable(core->owner_ruby_thread);
}

static void
tc_core_map_compact(void *opaque)
{
    tc_core_map *core = opaque;
    if (core == NULL) return;
    tc_map_compact_node(core->map.root);
    core->owner_fiber = rb_gc_location(core->owner_fiber);
    core->owner_ruby_thread = rb_gc_location(core->owner_ruby_thread);
    core->publication_owner_fiber =
        rb_gc_location(core->publication_owner_fiber);
    core->publication_owner_ruby_thread =
        rb_gc_location(core->publication_owner_ruby_thread);
}

static void
tc_core_map_free(void *opaque)
{
    tc_core_map *core = opaque;

    if (core == NULL) return;
    tc_map_free_node(core->map.root);
    if (core->mutex_initialized) pthread_mutex_destroy(&core->lock);
    xfree(core);
}

static size_t
tc_core_map_memsize(const void *opaque)
{
    const tc_core_map *core = opaque;

    return core == NULL
        ? 0
        : sizeof(*core) + core->map.size * sizeof(tc_map_node);
}

static const rb_data_type_t tc_unsafe_map_type = {
    .wrap_struct_name = "Farce::Internal::UnsafeTreeMap",
    .function = {
        .dmark = tc_core_map_mark,
        .dfree = tc_core_map_free,
        .dsize = tc_core_map_memsize,
        .dcompact = tc_core_map_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static const rb_data_type_t tc_map_type = {
    .wrap_struct_name = "Farce::Internal::TreeMap",
    .function = {
        .dmark = tc_core_map_mark,
        .dfree = tc_core_map_free,
        .dsize = tc_core_map_memsize,
        .dcompact = tc_core_map_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static const rb_data_type_t tc_shared_map_type = {
    .wrap_struct_name = "Farce::Internal::ShareableTreeMap",
    .function = {
        .dmark = tc_core_map_mark,
        .dfree = tc_core_map_free,
        .dsize = tc_core_map_memsize,
        .dcompact = tc_core_map_compact,
    },
    .flags = RUBY_TYPED_FROZEN_SHAREABLE,
};

static VALUE
tc_core_map_allocate(VALUE klass, const rb_data_type_t *type,
                     bool synchronized, bool shareable_container)
{
    tc_core_map *core;
    VALUE self = TypedData_Make_Struct(klass, tc_core_map, type, core);
    int error;

    core->map.root = NULL;
    core->map.size = 0;
    core->map.guard = 0;
    core->owner_fiber = Qnil;
    core->owner_ruby_thread = Qnil;
    core->waiters = NULL;
    core->last_waiter = NULL;
    core->publication_owner_fiber = Qnil;
    core->publication_owner_ruby_thread = Qnil;
    core->mutex_initialized = false;
    core->synchronized = synchronized;
    core->shareable_container = shareable_container;
    RUBY_ATOMIC_SET(core->publication_state, TC_MAP_UNINITIALIZED);

    if (synchronized) {
        error = pthread_mutex_init(&core->lock, NULL);
        if (error != 0) rb_syserr_fail(error, "pthread_mutex_init");
        core->mutex_initialized = true;
    }
    return self;
}

static VALUE
tc_unsafe_map_allocate(VALUE klass)
{
    return tc_core_map_allocate(klass, &tc_unsafe_map_type, false, false);
}

static VALUE
tc_map_allocate(VALUE klass)
{
    return tc_core_map_allocate(klass, &tc_map_type, true, false);
}

static VALUE
tc_shareable_map_allocate(VALUE klass)
{
    return tc_core_map_allocate(klass, &tc_shared_map_type, true, true);
}

static tc_core_map *
tc_core_map_get_raw(VALUE self)
{
    tc_core_map *core;

    if (rb_typeddata_is_kind_of(self, &tc_unsafe_map_type)) {
        TypedData_Get_Struct(self, tc_core_map, &tc_unsafe_map_type, core);
        return core;
    }
    if (rb_typeddata_is_kind_of(self, &tc_map_type)) {
        TypedData_Get_Struct(self, tc_core_map, &tc_map_type, core);
        return core;
    }
    if (rb_typeddata_is_kind_of(self, &tc_shared_map_type)) {
        TypedData_Get_Struct(self, tc_core_map, &tc_shared_map_type, core);
        return core;
    }
    rb_raise(rb_eTypeError, "wrong tree map type");
}

static void
tc_core_map_validate_references(VALUE self)
{
    tc_core_map *core;
    TypedData_Get_Struct(self, tc_core_map, &tc_shared_map_type, core);
    tc_map_validate_shareable_node(core->map.root);
}

static tc_core_map *
tc_core_map_get(VALUE self)
{
    tc_core_map *core = tc_core_map_get_raw(self);

    if (core->synchronized) {
        rb_atomic_t state = RUBY_ATOMIC_LOAD(core->publication_state);

        /* A clean frozen typed object can become visible before recursive
         * publication returns. Join every active publication, then recheck so
         * a failed traversal cannot expose a half-published shared map. The
         * steady-state path is one atomic load. */
        if (tc_core_map_publication_busy(state)) {
            tc_core_map_wait_for_publication(self, core);
            state = RUBY_ATOMIC_LOAD(core->publication_state);
        }
        if (state != TC_MAP_INITIALIZED) {
            rb_raise(rb_eRuntimeError, "uninitialized tree map");
        }
        return core;
    }
    if (RUBY_ATOMIC_LOAD(core->publication_state) != TC_MAP_INITIALIZED) {
        rb_raise(rb_eRuntimeError, "uninitialized tree map");
    }
    return core;
}

typedef struct {
    tc_core_map *core;
    tc_core_map_waiter waiter;
} tc_core_map_fiber_wait;

static void
tc_core_map_set_fd_flags(int fd)
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

/* Called with core->lock held. The waiter remains linked until its ensure
 * cleanup so an interrupt cannot leave a dangling stack pointer behind. */
static void
tc_core_map_notify_one_locked(tc_core_map *core)
{
    unsigned char byte = 1;

    for (tc_core_map_waiter *waiter = core->waiters;
         waiter != NULL;
         waiter = waiter->next) {
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

static VALUE
tc_core_map_fiber_wait_body(VALUE opaque)
{
    tc_core_map_fiber_wait *wait = (tc_core_map_fiber_wait *)opaque;
    return containers_wait_for_readable(wait->waiter.read_fd, Qnil) ? Qtrue : Qfalse;
}

static VALUE
tc_core_map_fiber_wait_cleanup(VALUE opaque)
{
    tc_core_map_fiber_wait *wait = (tc_core_map_fiber_wait *)opaque;
    tc_core_map_waiter *previous = NULL;
    tc_core_map_waiter **cursor;

    pthread_mutex_lock(&wait->core->lock);
    for (cursor = &wait->core->waiters; *cursor != NULL; cursor = &(*cursor)->next) {
        if (*cursor == &wait->waiter) {
            *cursor = wait->waiter.next;
            if (wait->core->last_waiter == &wait->waiter) {
                wait->core->last_waiter = previous;
            }
            break;
        }
        previous = *cursor;
    }
    /* Notification makes a waiter runnable, but does not reserve ownership.
     * Always pass the baton if a notified waiter leaves while ownerless,
     * including cancellation after rb_io_wait returned but before the lock
     * acquisition loop claimed ownership. */
    if (wait->waiter.notified &&
        NIL_P(wait->core->owner_fiber) &&
        !tc_core_map_publication_busy(
            RUBY_ATOMIC_LOAD(wait->core->publication_state)
        )) {
        tc_core_map_notify_one_locked(wait->core);
    }
    pthread_mutex_unlock(&wait->core->lock);

    close(wait->waiter.read_fd);
    close(wait->waiter.write_fd);
    return Qnil;
}

/* Called with core->lock held and always returns with it released. */
static void
tc_core_map_wait_once(tc_core_map *core)
{
    int descriptors[2];

    if (pipe(descriptors) != 0) {
        pthread_mutex_unlock(&core->lock);
        rb_sys_fail("pipe");
    }
    tc_core_map_set_fd_flags(descriptors[0]);
    tc_core_map_set_fd_flags(descriptors[1]);

    tc_core_map_fiber_wait wait = {
        .core = core,
        .waiter = {
            .read_fd = descriptors[0],
            .write_fd = descriptors[1],
            .notified = false,
            .next = NULL,
        },
    };

    if (core->last_waiter != NULL) core->last_waiter->next = &wait.waiter;
    else core->waiters = &wait.waiter;
    core->last_waiter = &wait.waiter;
    pthread_mutex_unlock(&core->lock);

    (void)rb_ensure(
        tc_core_map_fiber_wait_body,
        (VALUE)&wait,
        tc_core_map_fiber_wait_cleanup,
        (VALUE)&wait
    );
}

/* CRuby needs logical Fiber ownership rather than pthread ownership: multiple
 * scheduled Fibers can contend on the same native thread. Descriptor waits
 * let rb_io_wait park only the current Fiber while its owner resumes. */
static void
tc_core_map_lock(VALUE self, tc_core_map *core)
{
    VALUE current = rb_fiber_current();
    VALUE current_thread = rb_thread_current();
    VALUE scheduler = rb_fiber_scheduler_current();

    (void)self;
    for (;;) {
        bool publication_busy;

        pthread_mutex_lock(&core->lock);
        publication_busy = tc_core_map_publication_busy(
            RUBY_ATOMIC_LOAD(core->publication_state)
        );
        if (core->owner_fiber == current ||
            (publication_busy && core->publication_owner_fiber == current)) {
            pthread_mutex_unlock(&core->lock);
            rb_raise(rb_eThreadError, "deadlock; recursive tree map access");
        }
        if (NIL_P(core->owner_fiber) && !publication_busy) {
            core->owner_fiber = current;
            core->owner_ruby_thread = current_thread;
            pthread_mutex_unlock(&core->lock);
            return;
        }
        if ((core->owner_ruby_thread == current_thread ||
             (publication_busy &&
              core->publication_owner_ruby_thread == current_thread)) &&
            NIL_P(scheduler)) {
            pthread_mutex_unlock(&core->lock);
            rb_raise(
                rb_eThreadError,
                "deadlock; tree map is owned by another unscheduled fiber"
            );
        }
        tc_core_map_wait_once(core);
    }
}

static void
tc_core_map_unlock(tc_core_map *core)
{
    rb_atomic_t state;

    pthread_mutex_lock(&core->lock);
    state = RUBY_ATOMIC_LOAD(core->publication_state);
    if (state == TC_MAP_PUBLISHED) {
        RUBY_ATOMIC_SET(core->publication_state, TC_MAP_INITIALIZED);
    }
    else if (state == TC_MAP_PUBLISHING) {
        RUBY_ATOMIC_SET(core->publication_state, TC_MAP_UNINITIALIZED);
    }
    core->owner_fiber = Qnil;
    core->owner_ruby_thread = Qnil;
    core->publication_owner_fiber = Qnil;
    core->publication_owner_ruby_thread = Qnil;
    tc_core_map_notify_one_locked(core);
    pthread_mutex_unlock(&core->lock);
}

typedef struct {
    VALUE self;
    tc_core_map *core;
    bool acquired;
} tc_core_map_publication_wait;

static VALUE
tc_core_map_publication_wait_body(VALUE opaque)
{
    tc_core_map_publication_wait *wait =
        (tc_core_map_publication_wait *)opaque;

    tc_core_map_lock(wait->self, wait->core);
    wait->acquired = true;
    return Qnil;
}

static VALUE
tc_core_map_publication_wait_ensure(VALUE opaque)
{
    tc_core_map_publication_wait *wait =
        (tc_core_map_publication_wait *)opaque;

    if (wait->acquired) tc_core_map_unlock(wait->core);
    return Qnil;
}

static void
tc_core_map_wait_for_publication(VALUE self, tc_core_map *core)
{
    tc_core_map_publication_wait wait = {
        .self = self,
        .core = core,
        .acquired = false,
    };

    /* Retaining the publisher as logical owner makes recursive publication
     * callbacks fail with the ordinary ThreadError, while other Ractors and
     * scheduler-managed Fibers park until the outer operation unlocks. */
    (void)rb_ensure(
        tc_core_map_publication_wait_body,
        (VALUE)&wait,
        tc_core_map_publication_wait_ensure,
        (VALUE)&wait
    );
}

typedef VALUE (*tc_core_map_operation)(VALUE opaque);

typedef struct {
    VALUE self;
    tc_core_map *core;
    VALUE key;
    VALUE value;
    bool found;
} tc_core_map_arguments;

typedef struct {
    tc_core_map_operation operation;
    VALUE argument;
} tc_core_map_call;

static VALUE
tc_core_map_call_body(VALUE opaque)
{
    tc_core_map_call *call = (tc_core_map_call *)opaque;
    return call->operation(call->argument);
}

static VALUE
tc_core_map_unlock_ensure(VALUE opaque)
{
    tc_core_map_unlock((tc_core_map *)opaque);
    return Qnil;
}

static VALUE
tc_core_map_call_locked(VALUE self, tc_core_map *core,
                        tc_core_map_operation operation,
                        tc_core_map_arguments *arguments)
{
    tc_core_map_call call;

    if (!core->synchronized) return operation((VALUE)arguments);
    tc_core_map_lock(self, core);
    call.operation = operation;
    call.argument = (VALUE)arguments;
    return rb_ensure(
        tc_core_map_call_body,
        (VALUE)&call,
        tc_core_map_unlock_ensure,
        (VALUE)core
    );
}

static void
tc_core_map_check_key(VALUE key)
{
    if (!rb_ractor_shareable_p(key)) {
        rb_raise(tc_eIsolationError, "key is not shareable: %" PRIsVALUE,
                 rb_inspect(key));
    }
}

static void
tc_core_map_check_value(const tc_core_map *core, VALUE value)
{
    if (core->shareable_container && !rb_ractor_shareable_p(value)) {
        rb_raise(tc_eIsolationError, "value is not shareable: %" PRIsVALUE,
                 rb_inspect(value));
    }
}

static void
tc_core_map_check_mutation(VALUE self, const tc_core_map *core)
{
    rb_check_frozen(self);
    if (core->map.guard != 0) {
        rb_raise(rb_eRuntimeError, "container cannot be modified during comparison");
    }
}

static int
tc_core_map_initialize_entry(VALUE key, VALUE value, VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;

    key = containers_normalize_string_key(key);
    tc_core_map_check_key(key);
    tc_core_map_check_value(arguments->core, value);
    tc_map_store_unlocked(
        arguments->self,
        &arguments->core->map,
        key,
        value,
        true
    );
    return ST_CONTINUE;
}

typedef struct {
    VALUE self;
    tc_core_map *core;
} tc_core_map_publication;

static VALUE
tc_core_map_make_shareable(VALUE opaque)
{
    tc_core_map_publication *publication =
        (tc_core_map_publication *)opaque;

    return containers_publish_native_with_references(
        publication->self,
        tc_core_map_validate_references
    );
}

static VALUE
tc_core_map_finish_publication(VALUE opaque)
{
    tc_core_map_publication *publication =
        (tc_core_map_publication *)opaque;
    bool shareable = rb_ractor_shareable_p(publication->self);

    /* rb_ractor_make_shareable can be interrupted after setting the object's
     * shareable flag. Publish the initialized bit whenever the object reached
     * that coherent state, even if the caller is about to receive an async
     * exception. The outer operation ensure retains the publishing state until
     * it clears the logical lock and wakes a waiter. */
    pthread_mutex_lock(&publication->core->lock);
    if (shareable) {
        RUBY_ATOMIC_SET(publication->core->publication_state, TC_MAP_PUBLISHED);
    }
    pthread_mutex_unlock(&publication->core->lock);
    return Qnil;
}

static VALUE
tc_core_map_publish_shareable(VALUE self, tc_core_map *core)
{
    tc_core_map_publication publication = {
        .self = self,
        .core = core,
    };

    /* Install the gate before primitive freeze can make this typed object
     * Ractor-visible. Move the logical owner out of dmark before recursive
     * sharing, while retaining it for callback reentry/deadlock detection. */
    pthread_mutex_lock(&core->lock);
    RUBY_ATOMIC_SET(core->publication_state, TC_MAP_PUBLISHING);
    core->publication_owner_fiber = core->owner_fiber;
    core->publication_owner_ruby_thread = core->owner_ruby_thread;
    core->owner_fiber = Qnil;
    core->owner_ruby_thread = Qnil;
    pthread_mutex_unlock(&core->lock);
    return rb_ensure(
        tc_core_map_make_shareable,
        (VALUE)&publication,
        tc_core_map_finish_publication,
        (VALUE)&publication
    );
}

static void
tc_core_map_check_initializable(VALUE self, tc_core_map *core)
{
    rb_atomic_t state = RUBY_ATOMIC_LOAD(core->publication_state);

    if (state == TC_MAP_INITIALIZED) {
        rb_raise(rb_eRuntimeError, "tree map is already initialized");
    }
    rb_check_frozen(self);

    /* Publication marks the object busy before primitive freeze. Reject the
     * narrow pre-freeze window here so a competing initializer cannot enter
     * #to_hash while publication is already in progress. */
    if (RUBY_ATOMIC_LOAD(core->publication_state) != TC_MAP_UNINITIALIZED) {
        rb_raise(rb_eRuntimeError, "tree map is already initialized");
    }
}

static VALUE
tc_core_map_initialize_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_core_map *core = arguments->core;

    /* #to_hash runs before this synchronized body and may itself initialize
     * the receiver. Two shared-map initializers can also pass the fast outer
     * check concurrently. The check under the operation lock is authoritative
     * and must precede every mutation. */
    if (RUBY_ATOMIC_LOAD(core->publication_state) != TC_MAP_UNINITIALIZED) {
        rb_raise(rb_eRuntimeError, "tree map is already initialized");
    }
    /* Shareable maps are frozen only after initialization succeeds. A freeze
     * performed before initialization or from #to_hash/comparison callbacks
     * must still prevent publication, just as it does for the ordinary
     * variants and the Ruby/JVM implementations. */
    rb_check_frozen(arguments->self);
    tc_core_map_check_mutation(arguments->self, core);
    tc_map_free_node(core->map.root);
    core->map.root = NULL;
    core->map.size = 0;
    if (!NIL_P(arguments->value)) {
        rb_hash_foreach(arguments->value, tc_core_map_initialize_entry, opaque);
    }

    if (core->shareable_container) {
        /* Publication installs its logical gate before primitive freezing and
         * keeps that whole transition under nested ensure cleanup. */
        return tc_core_map_publish_shareable(arguments->self, core);
    }
    RUBY_ATOMIC_SET(core->publication_state, TC_MAP_INITIALIZED);
    return arguments->self;
}

static VALUE
tc_core_map_initialize(int argc, VALUE *argv, VALUE self)
{
    tc_core_map *core = tc_core_map_get_raw(self);
    tc_core_map_arguments arguments = {
        .self = self,
        .core = core,
        .key = Qnil,
        .value = Qnil,
    };
    VALUE entries = Qnil;
    VALUE hash;

    rb_scan_args(argc, argv, "01", &entries);
    tc_core_map_check_initializable(self, core);

    if (!NIL_P(entries)) {
        hash = rb_check_hash_type(entries);
        if (NIL_P(hash)) {
            rb_raise(rb_eTypeError, "entries must be a Hash or respond to #to_hash");
        }
        arguments.value = hash;
    }

    /* A descendant's #freeze can recursively call #initialize while the first
     * publication is traversing its instance variables. The shared receiver is
     * primitively frozen before that traversal, so reject the recursive call
     * here, before it can wait on the publisher's logical lock. */
    tc_core_map_check_initializable(self, core);

    return tc_core_map_call_locked(
        self,
        core,
        tc_core_map_initialize_body,
        &arguments
    );
}

static VALUE
tc_core_map_initialize_copy(VALUE self, VALUE other)
{
    (void)self;
    (void)other;
    rb_raise(rb_eTypeError, "tree maps cannot be copied");
}

static VALUE
tc_core_map_aref_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map_node *node = tc_map_find(
        &arguments->core->map,
        arguments->key,
        NULL,
        NULL
    );

    arguments->found = node != NULL;
    return node == NULL ? Qnil : node->value;
}

static VALUE
tc_core_map_aref(VALUE self, VALUE key)
{
    tc_core_map *core = tc_core_map_get(self);

    key = containers_normalize_string_key(key);
    tc_core_map_arguments arguments = {
        .self = self,
        .core = core,
        .key = key,
        .value = Qnil,
    };

    tc_core_map_check_key(key);
    return tc_core_map_call_locked(self, core, tc_core_map_aref_body, &arguments);
}

static VALUE
tc_core_map_prepare_key(VALUE self, VALUE key)
{
    (void)tc_core_map_get(self);
    key = containers_normalize_string_key(key);
    tc_core_map_check_key(key);
    return key;
}

static VALUE
tc_core_map_fetch(int argc, VALUE *argv, VALUE self)
{
    VALUE key;
    VALUE normalized_key;
    VALUE default_value;
    VALUE result;
    bool default_given;
    bool block_given;
    tc_core_map *core;
    tc_core_map_arguments arguments;

    rb_scan_args(argc, argv, "11", &key, &default_value);
    default_given = argc == 2;
    block_given = rb_block_given_p();
    if (block_given && default_given) {
        rb_warn("block supersedes default value argument");
    }

    core = tc_core_map_get(self);
    normalized_key = containers_normalize_string_key(key);
    arguments = (tc_core_map_arguments){
        .self = self,
        .core = core,
        .key = normalized_key,
        .value = Qnil,
        .found = false,
    };
    tc_core_map_check_key(normalized_key);
    result = tc_core_map_call_locked(
        self,
        core,
        tc_core_map_aref_body,
        &arguments
    );

    if (arguments.found) return result;
    if (block_given) return rb_yield(key);
    if (default_given) return default_value;
    containers_raise_key_error(self, key);
    return Qnil;
}

static VALUE
tc_core_map_key_p(VALUE self, VALUE key)
{
    tc_core_map *core = tc_core_map_get(self);

    key = containers_normalize_string_key(key);
    tc_core_map_arguments arguments = {
        .self = self,
        .core = core,
        .key = key,
        .value = Qnil,
        .found = false,
    };

    tc_core_map_check_key(key);
    (void)tc_core_map_call_locked(
        self,
        core,
        tc_core_map_aref_body,
        &arguments
    );
    return arguments.found ? Qtrue : Qfalse;
}

static VALUE
tc_core_map_getkey_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map_node *node = tc_map_find(
        &arguments->core->map,
        arguments->key,
        NULL,
        NULL
    );

    return node == NULL ? Qnil : node->key;
}

static VALUE
tc_core_map_getkey(VALUE self, VALUE key)
{
    tc_core_map *core = tc_core_map_get(self);

    key = containers_normalize_string_key(key);
    tc_core_map_arguments arguments = {
        .self = self,
        .core = core,
        .key = key,
        .value = Qnil,
    };

    tc_core_map_check_key(key);
    return tc_core_map_call_locked(
        self,
        core,
        tc_core_map_getkey_body,
        &arguments
    );
}

static VALUE
tc_core_map_store_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;

    tc_core_map_check_mutation(arguments->self, arguments->core);
    return tc_map_store_unlocked(
        arguments->self,
        &arguments->core->map,
        arguments->key,
        arguments->value,
        true
    );
}

static VALUE
tc_core_map_store(VALUE self, VALUE key, VALUE value)
{
    tc_core_map *core = tc_core_map_get(self);

    key = containers_normalize_string_key(key);
    tc_core_map_arguments arguments = {
        .self = self,
        .core = core,
        .key = key,
        .value = value,
    };

    tc_core_map_check_key(key);
    tc_core_map_check_value(core, value);
    return tc_core_map_call_locked(self, core, tc_core_map_store_body, &arguments);
}

static VALUE
tc_core_map_delete_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map *map = &arguments->core->map;
    tc_map_node *node;
    VALUE value;

    tc_core_map_check_mutation(arguments->self, arguments->core);
    node = tc_map_find(map, arguments->key, NULL, NULL);
    if (node == NULL) return Qnil;

    tc_core_map_check_mutation(arguments->self, arguments->core);
    value = node->value;
    tc_remove_link(&map->root, &node->link);
    map->size--;
    xfree(node);
    return value;
}

static VALUE
tc_core_map_delete(VALUE self, VALUE key)
{
    tc_core_map *core = tc_core_map_get(self);

    key = containers_normalize_string_key(key);
    tc_core_map_arguments arguments = {
        .self = self,
        .core = core,
        .key = key,
        .value = Qnil,
    };

    tc_core_map_check_key(key);
    return tc_core_map_call_locked(self, core, tc_core_map_delete_body, &arguments);
}

static VALUE
tc_core_map_first_key_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_link *first = tc_link_minimum(arguments->core->map.root);

    return first == NULL ? Qnil : TC_MAP_NODE(first)->key;
}

static VALUE
tc_core_map_first_key(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_first_key_body, &arguments);
}

static VALUE
tc_core_map_last_key_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_link *last = tc_link_maximum(arguments->core->map.root);

    return last == NULL ? Qnil : TC_MAP_NODE(last)->key;
}

static VALUE
tc_core_map_last_key(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_last_key_body, &arguments);
}

static VALUE
tc_core_map_shift_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map *map = &arguments->core->map;
    tc_link *first;
    tc_map_node *node;
    VALUE pair;

    tc_core_map_check_mutation(arguments->self, arguments->core);
    first = tc_link_minimum(map->root);
    if (first == NULL) return Qnil;

    node = TC_MAP_NODE(first);
    pair = rb_assoc_new(node->key, node->value);
    tc_remove_link(&map->root, first);
    map->size--;
    xfree(node);
    return pair;
}

static VALUE
tc_core_map_shift(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_shift_body, &arguments);
}

static VALUE
tc_core_map_pop_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map *map = &arguments->core->map;
    tc_link *last;
    tc_map_node *node;
    VALUE pair;

    tc_core_map_check_mutation(arguments->self, arguments->core);
    last = tc_link_maximum(map->root);
    if (last == NULL) return Qnil;

    node = TC_MAP_NODE(last);
    pair = rb_assoc_new(node->key, node->value);
    tc_remove_link(&map->root, last);
    map->size--;
    xfree(node);
    return pair;
}

static VALUE
tc_core_map_pop(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_pop_body, &arguments);
}

static VALUE
tc_core_map_size_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    return SIZET2NUM(arguments->core->map.size);
}

static VALUE
tc_core_map_size(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_size_body, &arguments);
}

static VALUE
tc_core_map_enumerator_size(VALUE self, VALUE arguments, VALUE enumerator)
{
    (void)arguments;
    (void)enumerator;
    return tc_core_map_size(self);
}

static void
tc_core_map_snapshot_node(tc_link *link, VALUE entries)
{
    tc_map_node *node;

    if (link == NULL) return;
    tc_core_map_snapshot_node(link->left, entries);
    node = TC_MAP_NODE(link);
    rb_ary_push(entries, node->key);
    rb_ary_push(entries, node->value);
    tc_core_map_snapshot_node(link->right, entries);
}

static VALUE
tc_core_map_snapshot_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map *map = &arguments->core->map;
    VALUE entries = rb_ary_new_capa((long)(map->size * 2));

    tc_core_map_snapshot_node(map->root, entries);
    return entries;
}

static VALUE
tc_core_map_each(VALUE self)
{
    VALUE entries;
    long entry_count;
    long index;
    tc_core_map *core;
    tc_core_map_arguments arguments;

    RETURN_SIZED_ENUMERATOR(self, 0, NULL, tc_core_map_enumerator_size);
    core = tc_core_map_get(self);
    arguments = (tc_core_map_arguments){.self = self, .core = core};
    entries = tc_core_map_call_locked(
        self,
        core,
        tc_core_map_snapshot_body,
        &arguments
    );
    entry_count = RARRAY_LEN(entries);
    for (index = 0; index < entry_count; index += 2) {
        rb_yield(rb_assoc_new(
            RARRAY_AREF(entries, index),
            RARRAY_AREF(entries, index + 1)
        ));
    }
    RB_GC_GUARD(entries);
    return self;
}

static VALUE
tc_core_map_empty_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    return arguments->core->map.size == 0 ? Qtrue : Qfalse;
}

static VALUE
tc_core_map_empty_p(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_empty_body, &arguments);
}

static VALUE
tc_core_map_clear_body(VALUE opaque)
{
    tc_core_map_arguments *arguments = (tc_core_map_arguments *)opaque;
    tc_map *map = &arguments->core->map;

    tc_core_map_check_mutation(arguments->self, arguments->core);
    tc_map_free_node(map->root);
    map->root = NULL;
    map->size = 0;
    return arguments->self;
}

static VALUE
tc_core_map_clear(VALUE self)
{
    tc_core_map *core = tc_core_map_get(self);
    tc_core_map_arguments arguments = {.self = self, .core = core};

    return tc_core_map_call_locked(self, core, tc_core_map_clear_body, &arguments);
}

static void
tc_core_map_define_methods(VALUE klass)
{
    rb_define_method(klass, "initialize", tc_core_map_initialize, -1);
    rb_define_method(klass, "initialize_copy", tc_core_map_initialize_copy, 1);
    rb_define_method(klass, "[]", tc_core_map_aref, 1);
    rb_define_method(klass, "prepare_key", tc_core_map_prepare_key, 1);
    rb_define_method(klass, "[]=", tc_core_map_store, 2);
    rb_define_method(klass, "fetch", tc_core_map_fetch, -1);
    rb_define_method(klass, "key?", tc_core_map_key_p, 1);
    rb_define_method(klass, "getkey", tc_core_map_getkey, 1);
    rb_define_method(klass, "each", tc_core_map_each, 0);
    rb_define_method(klass, "delete", tc_core_map_delete, 1);
    rb_define_method(klass, "first_key", tc_core_map_first_key, 0);
    rb_define_method(klass, "last_key", tc_core_map_last_key, 0);
    rb_define_method(klass, "shift", tc_core_map_shift, 0);
    rb_define_method(klass, "pop", tc_core_map_pop, 0);
    rb_define_method(klass, "size", tc_core_map_size, 0);
    rb_define_method(klass, "length", tc_core_map_size, 0);
    rb_define_method(klass, "empty?", tc_core_map_empty_p, 0);
    rb_define_method(klass, "clear", tc_core_map_clear, 0);
}
void
containers_init_tree_maps(VALUE internal)
{
    VALUE unsafe_map_class;
    VALUE map_class;
    VALUE shareable_map_class;
    VALUE ractor;
    ID ractor_id = rb_intern("Ractor");

    tc_id_compare = rb_intern("<=>");
    ractor = rb_const_get(rb_cObject, ractor_id);
    tc_eIsolationError = rb_const_get(ractor, rb_intern("IsolationError"));

    unsafe_map_class = rb_define_class_under(internal, "UnsafeTreeMap", rb_cObject);
    rb_define_alloc_func(unsafe_map_class, tc_unsafe_map_allocate);
    tc_core_map_define_methods(unsafe_map_class);

    map_class = rb_define_class_under(internal, "TreeMap", rb_cObject);
    rb_define_alloc_func(map_class, tc_map_allocate);
    tc_core_map_define_methods(map_class);

    shareable_map_class = rb_define_class_under(
        internal,
        "ShareableTreeMap",
        rb_cObject
    );
    rb_define_alloc_func(shareable_map_class, tc_shareable_map_allocate);
    tc_core_map_define_methods(shareable_map_class);
}
