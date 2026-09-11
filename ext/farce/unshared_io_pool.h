#ifndef FARCE_UNSHARED_IO_POOL_H
#define FARCE_UNSHARED_IO_POOL_H

#include "unshared_wait.h"
#include "ruby/io.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

/* Each pair belongs to its Ruby IO objects. Native code never closes their
 * descriptors. A slot stays active until io_wait returns or unwinds, so no
 * scheduler can observe a descriptor reassigned to another pending wait. */
typedef struct farce_io_slot farce_io_slot_t;
struct farce_io_slot {
    VALUE reader;
    VALUE writer;
    int read_fd;
    int write_fd;
    bool notified;
    bool broken;
    farce_io_slot_t *all_previous;
    farce_io_slot_t *all_next;
    farce_io_slot_t *idle_next;
    farce_io_slot_t *previous;
    farce_io_slot_t *next;
};

typedef struct {
    farce_io_slot_t *all;
    farce_io_slot_t *idle;
    farce_io_slot_t *active;
    size_t idle_count;
    size_t active_count;
    size_t size;
} farce_io_pool_t;

#define FARCE_IO_POOL_IDLE_LIMIT 2

static void
farce_io_pool_mark(farce_io_pool_t *pool)
{
    for (farce_io_slot_t *slot = pool->all; slot; slot = slot->all_next) {
        rb_gc_mark(slot->reader);
        rb_gc_mark(slot->writer);
    }
}

static void
farce_io_pool_free(farce_io_pool_t *pool)
{
    farce_io_slot_t *slot = pool->all;
    while (slot) {
        farce_io_slot_t *next = slot->all_next;
        /* Ruby finalizes the IO objects and their owned descriptors. */
        free(slot);
        slot = next;
    }
}

static size_t
farce_io_pool_memsize(farce_io_pool_t *pool)
{
    return pool->size * sizeof(farce_io_slot_t);
}

static VALUE
farce_io_pool_descriptor(VALUE io)
{
    return INT2NUM(rb_io_descriptor(io));
}

static void
farce_io_pool_discard(farce_io_pool_t *pool, farce_io_slot_t *slot)
{
    if (slot->all_previous) slot->all_previous->all_next = slot->all_next;
    else pool->all = slot->all_next;
    if (slot->all_next) slot->all_next->all_previous = slot->all_previous;
    pool->size--;
    VALUE reader = slot->reader;
    VALUE writer = slot->writer;
    free(slot);
    /* Cleanup must close both ends without masking the original exception. */
    VALUE error = rb_errinfo();
    int state;
    rb_protect(rb_io_close, reader, &state);
    rb_set_errinfo(error);
    rb_protect(rb_io_close, writer, &state);
    rb_set_errinfo(error);
    RB_GC_GUARD(reader);
    RB_GC_GUARD(writer);
    RB_GC_GUARD(error);
}

static farce_io_slot_t *
farce_io_pool_acquire(farce_io_pool_t *pool)
{
    if (pool->idle) {
        farce_io_slot_t *slot = pool->idle;
        pool->idle = slot->idle_next;
        pool->idle_count--;
        slot->idle_next = NULL;
        return slot;
    }

    /* IO.pipe supplies fully owned, exception-safe Ruby handles. If setup
     * raises before the slot is linked, Ruby still owns both descriptors. */
    VALUE pair = rb_funcall(rb_cIO, rb_intern("pipe"), 0);
    VALUE reader = rb_ary_entry(pair, 0);
    VALUE writer = rb_ary_entry(pair, 1);
    int read_fd = rb_io_descriptor(reader);
    int write_fd = rb_io_descriptor(writer);
#ifndef _WIN32
    int read_flags = fcntl(read_fd, F_GETFL, 0);
    int write_flags = fcntl(write_fd, F_GETFL, 0);
    if (read_flags < 0 || write_flags < 0 ||
        fcntl(read_fd, F_SETFL, read_flags | O_NONBLOCK) < 0 ||
        fcntl(write_fd, F_SETFL, write_flags | O_NONBLOCK) < 0) rb_sys_fail("fcntl");
#endif
    farce_io_slot_t *slot = calloc(1, sizeof(*slot));
    if (!slot) rb_memerror();
    slot->reader = reader;
    slot->writer = writer;
    slot->read_fd = read_fd;
    slot->write_fd = write_fd;
    slot->all_next = pool->all;
    if (slot->all_next) slot->all_next->all_previous = slot;
    pool->all = slot;
    pool->size++;
    RB_GC_GUARD(pair);
    return slot;
}

static void
farce_io_pool_release(farce_io_pool_t *pool, farce_io_slot_t *slot)
{
    VALUE error = rb_errinfo();
    int state;
    VALUE descriptor = rb_protect(farce_io_pool_descriptor, slot->reader, &state);
    rb_set_errinfo(error);
    if (state || NUM2INT(descriptor) != slot->read_fd) slot->broken = true;
    if (!slot->broken && slot->notified) {
        unsigned char byte;
        ssize_t count;
        do { count = read(slot->read_fd, &byte, 1); } while (count < 0 && errno == EINTR);
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) slot->broken = true;
    }
    slot->notified = false;
    if (slot->broken || pool->idle_count == FARCE_IO_POOL_IDLE_LIMIT) {
        farce_io_pool_discard(pool, slot);
    }
    else {
        slot->idle_next = pool->idle;
        pool->idle = slot;
        pool->idle_count++;
    }
    RB_GC_GUARD(error);
}

static void
farce_io_pool_notify(farce_io_pool_t *pool)
{
    const unsigned char byte = 1;
    for (farce_io_slot_t *slot = pool->active; slot; slot = slot->next) {
        if (slot->notified || slot->broken) continue;
        ssize_t count;
        do { count = write(slot->write_fd, &byte, 1); } while (count < 0 && errno == EINTR);
        if (count == 1 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) slot->notified = true;
        else slot->broken = true;
    }
}

typedef struct {
    farce_io_pool_t *pool;
    farce_io_slot_t *slot;
    bool (*ready)(void *);
    void *data;
    bool finite;
    double deadline;
    bool registered;
    bool completed;
} farce_io_pool_wait_t;

static VALUE
farce_io_pool_wait_body(VALUE opaque)
{
    farce_io_pool_wait_t *wait = (farce_io_pool_wait_t *)opaque;
    wait->slot = farce_io_pool_acquire(wait->pool);
    /* Acquiring a new pipe may run Ruby. Recheck the caller's condition before
     * registering under the GVL, including notifications during allocation. */
    if (wait->ready(wait->data)) { wait->completed = true; return Qtrue; }
    double remaining = wait->finite ? wait->deadline - farce_unshared_wait_now() : 0;
    if (wait->finite && remaining <= 0) { wait->completed = true; return Qfalse; }
    farce_io_slot_t *slot = wait->slot;
    /* Older CRuby versions dispatch io_wait without checking a closed IO.
     * Validate before handing a cached object back to the scheduler. */
    if (rb_io_descriptor(slot->reader) != slot->read_fd) rb_raise(rb_eIOError, "queue wait descriptor changed");
    slot->previous = NULL;
    slot->next = wait->pool->active;
    if (slot->next) slot->next->previous = slot;
    wait->pool->active = slot;
    wait->pool->active_count++;
    wait->registered = true;
    VALUE result = rb_io_wait(slot->reader, INT2NUM(RUBY_IO_READABLE), wait->finite ? DBL2NUM(remaining) : Qnil);
    wait->completed = true;
    return result;
}

static VALUE
farce_io_pool_wait_cleanup(VALUE opaque)
{
    farce_io_pool_wait_t *wait = (farce_io_pool_wait_t *)opaque;
    if (!wait->slot) return Qnil;
    farce_io_slot_t *slot = wait->slot;
    if (wait->registered) {
        if (slot->previous) slot->previous->next = slot->next;
        else wait->pool->active = slot->next;
        if (slot->next) slot->next->previous = slot->previous;
        wait->pool->active_count--;
    }
    /* An interrupted scheduler may have started closing its IO. Finish that
     * close after rb_io_wait unwinds, and never reuse an exceptional slot. */
    if (!wait->completed) slot->broken = true;
    farce_io_pool_release(wait->pool, slot);
    return Qnil;
}

static bool
farce_io_pool_wait(farce_io_pool_t *pool, bool finite, double deadline, bool (*ready)(void *), void *data)
{
    farce_io_pool_wait_t wait = {.pool = pool, .finite = finite, .deadline = deadline, .ready = ready, .data = data};
    return RTEST(rb_ensure(farce_io_pool_wait_body, (VALUE)&wait, farce_io_pool_wait_cleanup, (VALUE)&wait));
}

#endif
