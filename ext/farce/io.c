#include "reactor.h"
#include <ruby/version.h>
#include <ruby/fiber/scheduler.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>

// BasicSocket is kept alive so reads can choose the socket path without loading it again.
static VALUE socket_class = Qnil;

// Remove the wait and its IO watches after a readiness call returns or raises.
static VALUE wait_cleanup(VALUE data) {
    VALUE *args = (VALUE *)data; return fs_retire(args[0], args[1]);
}

// Watch the requested IO events and suspend the current fiber.
// A timeout resumes it with zero when no event arrives in time.
static VALUE wait_body(VALUE data) {
    VALUE *args = (VALUE *)data;
    fs_state *s = fs_get(args[0]); fs_wait *w = fs_lookup(s, args[1]);
    w->ios = args[2]; // GC root for the watched IO
    fs_watch_io(s, w, rb_io_descriptor(args[2]), NUM2INT(args[3]), -1, 0);
    if (NIL_P(args[4])) return fs_suspend(args[0], args[1]);
    return rb_funcall(args[0], rb_intern("wait_with_timeout"), 3, args[1], args[4], INT2NUM(0));
}

// Create a readiness wait and make sure it is cleaned up on every exit.
// The caller has already checked that this fiber belongs to the scheduler.
static VALUE wait_for(VALUE self, VALUE io, int events, VALUE timeout) {
    VALUE args[] = {self, fs_arm_checked(self), io, INT2NUM(events), timeout};
    return rb_ensure(wait_body, (VALUE)args, wait_cleanup, (VALUE)args);
}

// Implement Ruby's io_wait hook. Return events that are ready now, or wait
// for an event or timeout. Even an immediate result gives other fibers a turn periodically.
VALUE fs_io_wait(int argc, VALUE *argv, VALUE self) {
    VALUE io, events, timeout;
    rb_scan_args(argc, argv, "21", &io, &events, &timeout);
    fs_check_fiber(self);
    io = rb_io_get_io(io);
    int mask = NUM2INT(events);
    timeout = rb_funcall(self, rb_intern("duration_value"), 1, timeout);
    fs_check_fiber(self);
    if (mask <= 0 || (mask & ~7)) rb_raise(rb_eArgError, "invalid IO event mask");
    struct pollfd fd = {.fd = rb_io_descriptor(io)};
    if (mask & FS_READ) fd.events |= POLLIN;
    if (mask & FS_WRITE) fd.events |= POLLOUT;
    if (mask & FS_PRI) fd.events |= POLLPRI;
    int result = poll(&fd, 1, 0);
    if (result < 0 && errno != EINTR) rb_sys_fail("scheduler readiness snapshot");
    if (fd.revents & POLLNVAL) rb_raise(rb_eIOError, "closed stream");
    int found = 0;
    if (fd.revents & (POLLIN | POLLHUP | POLLERR)) found |= FS_READ;
    if (fd.revents & (POLLOUT | POLLHUP | POLLERR)) found |= FS_WRITE;
    if (fd.revents & POLLPRI) found |= FS_PRI;
    if ((found & mask) || (!NIL_P(timeout) && NUM2DBL(timeout) == 0))
        return fs_checkpoint(self, INT2NUM(found & mask));
    return wait_for(self, io, mask, timeout);
}

// Keep the state of one buffer read or write across waits and cleanup.
// The Ruby IO and buffer stay alive while native code uses their storage.
typedef struct {
    // Ruby objects for the call and its current wait token.
    VALUE self, io, buffer, token;
    // Completion target, starting offset, buffer limit, and bytes already written.
    size_t minimum, offset, size, initial;
    // Start of the buffer storage used by native IO calls.
    void *base;
    // Write mode, lock ownership, original descriptor, and socket-call mode.
    int writing, unlock, fd, socket;
    // Suspension count before this call, used to detect an immediate result.
    uint64_t serial;
} transfer;

// Pause a transfer until its descriptor is ready, then remove that wait.
// If the wait raises, transfer_cleanup removes it instead.
static void transfer_wait(transfer *t, int events) {
    t->token = fs_arm_checked(t->self);
    fs_state *s = fs_get(t->self);
    fs_wait *w = fs_lookup(s, t->token);
    w->ios = t->io;
    fs_watch_io(s, w, rb_io_descriptor(t->io), events, -1, 0);
    fs_suspend(t->self, t->token);
    fs_retire(t->self, t->token);
    t->token = Qnil;
}

// Submit an io_uring receive directly into the locked buffer and wait for it.
// Return the byte count or a negative error number from the completion.
static ssize_t transfer_receive(transfer *t, void *buffer, size_t capacity) {
    t->token = fs_arm_checked(t->self);
    fs_state *s = fs_get(t->self);
    fs_wait *w = fs_lookup(s, t->token);
    w->ios = t->io;
    int error = fs_driver_receive(s, w, rb_io_descriptor(t->io), buffer, capacity);
    if (error) rb_syserr_fail(error, "scheduler receive submission");
    VALUE result = fs_suspend(t->self, t->token);
    fs_retire(t->self, t->token);
    t->token = Qnil;
    return NUM2LONG(result);
}

// Pass a regular file transfer to the Ruby helper and its bounded worker pool.
// The byte limit keeps the worker inside the requested buffer range.
static VALUE transfer_file(transfer *t) {
    return rb_funcall(t->self, rb_intern("file_transfer"), 6,
        t->writing ? Qtrue : Qfalse, t->io, t->buffer, SIZET2NUM(t->minimum),
        SIZET2NUM(t->offset), SIZET2NUM(t->size - t->offset));
}

// Read or write the requested bytes without blocking the scheduler thread.
// Wait when the IO is not ready, and use a worker for regular files.
// Return bytes transferred, or a negative error number if nothing was transferred.
static VALUE transfer_body(VALUE data) {
    transfer *t = (transfer *)data;
    // MSG_DONTWAIT is scoped to this syscall. Try sockets directly: this also
    // supports IO.for_fd wrappers without caching descriptor type across reopen.
#ifdef MSG_DONTWAIT
    t->socket = 1;
#else
    t->socket = 0;
    struct stat info;
    if (fstat(t->fd, &info) < 0) rb_sys_fail("scheduler fstat");
    if (S_ISREG(info.st_mode))
        return transfer_file(t);
    int flags = fcntl(t->fd, F_GETFL);
    if (flags < 0 || (!(flags & O_NONBLOCK) && fcntl(t->fd, F_SETFL, flags | O_NONBLOCK) < 0))
        rb_sys_fail("scheduler nonblocking IO");
#endif
    int direct = 0;
#if defined(FARCE_URING) && defined(IORING_RECVSEND_POLL_FIRST)
    fs_state *state = fs_get(t->self);
    direct = !t->writing && t->minimum > 0 && state->driver == FS_URING_DRIVER &&
        !state->receive_disabled && !NIL_P(socket_class) && rb_obj_is_kind_of(t->io, socket_class);
#endif
    if (!direct && !t->writing && t->size > t->offset &&
        !NIL_P(socket_class) && rb_obj_is_kind_of(t->io, socket_class)) {
        transfer_wait(t, FS_READ);
    }
    size_t total = 0;
    for (;;) {
        size_t capacity = t->size - t->offset - total;
        if (!capacity) return SIZET2NUM(total);
        // Recheck IO identity after each suspension. A numeric fd may have been
        // reused, while this call still retains the original Ruby IO object.
        if (rb_io_descriptor(t->io) != t->fd) rb_raise(rb_eIOError, "IO descriptor changed while waiting");
        ssize_t count;
        int socket_flags = 0;
#ifdef MSG_DONTWAIT
        socket_flags |= MSG_DONTWAIT;
#endif
#ifdef MSG_NOSIGNAL
        if (t->writing) socket_flags |= MSG_NOSIGNAL;
#endif
        if (direct) {
            count = transfer_receive(t, (char *)t->base + t->offset + total, capacity);
            if (count < 0) { errno = (int)-count; count = -1; }
        } else if (t->socket) {
            count = t->writing ? send(t->fd, (char *)t->base + t->offset + total, capacity, socket_flags) :
                recv(t->fd, (char *)t->base + t->offset + total, capacity, socket_flags);
        } else {
            count = t->writing ? write(t->fd, (char *)t->base + t->offset + total, capacity) :
                read(t->fd, (char *)t->base + t->offset + total, capacity);
        }
        if (count < 0) {
            int error = errno;
            if (direct && (error == EINVAL || error == EOPNOTSUPP || error == ENOSYS)) {
                // Older kernels may support the ring but not poll-first receive.
                // Fall back to readiness for this call and subsequent transfers.
                fs_get(t->self)->receive_disabled = 1;
                direct = 0;
                continue;
            }
            if (t->socket && error == ENOTSOCK) {
                struct stat info;
                if (fstat(t->fd, &info) < 0) rb_sys_fail("scheduler fstat");
                if (S_ISREG(info.st_mode))
                    return transfer_file(t);
                t->socket = 0;
                int flags = fcntl(t->fd, F_GETFL);
                if (flags < 0 || (!(flags & O_NONBLOCK) && fcntl(t->fd, F_SETFL, flags | O_NONBLOCK) < 0))
                    rb_sys_fail("scheduler nonblocking IO");
                continue;
            }
            if (error == EINTR) { rb_thread_check_ints(); continue; }
            if (error == EAGAIN || error == EWOULDBLOCK) {
                transfer_wait(t, t->writing ? FS_WRITE : FS_READ);
                continue;
            }
            return total ? SIZET2NUM(total) : INT2NUM(-error);
        }
        if (!count) return SIZET2NUM(total);
        total += (size_t)count;
        if (total >= t->minimum) return SIZET2NUM(total);
    }
}

// Adapt the transfer loop to the callback signature used by a Ruby block.
static VALUE timed_body(RB_BLOCK_CALL_FUNC_ARGLIST(ignored, data)) { return transfer_body(data); }

// Run the transfer while its buffer is protected.
// Apply the IO object's timeout when this Ruby version supports one.
static VALUE transfer_locked(VALUE data) {
    transfer *t = (transfer *)data;
#ifdef HAVE_RB_IO_TIMEOUT
    VALUE timeout = rb_io_timeout(t->io);
    if (!NIL_P(timeout)) return rb_block_call(t->self, rb_intern("with_io_timeout"), 1, &timeout, timed_body, data);
#endif
    return transfer_body(data);
}

// Cancel any remaining wait before releasing the buffer lock owned by this call.
// This also runs when a transfer raises or is interrupted.
static VALUE transfer_cleanup(VALUE data) {
    transfer *t = (transfer *)data;
    if (!NIL_P(t->token)) fs_retire(t->self, t->token);
    if (t->unlock) rb_io_buffer_unlock(t->buffer);
    return Qnil;
}

// Check Ruby's buffer arguments and prepare a read or write.
// Try an immediate socket write first, then protect the buffer for any waits.
// Ruby 4.1 requests a maximum length, while older versions request a minimum.
static VALUE transfer_io(int argc, VALUE *argv, VALUE self, int writing) {
    VALUE io, buffer, minimum, offset;
#if RUBY_FIBER_SCHEDULER_VERSION >= 4
    rb_scan_args(argc, argv, "40", &io, &buffer, &offset, &minimum);
#else
    rb_scan_args(argc, argv, "31", &io, &buffer, &minimum, &offset);
#endif
    fs_check_fiber(self);
    int coerces = !RB_TYPE_P(io, T_FILE) || !FIXNUM_P(minimum) || (!NIL_P(offset) && !FIXNUM_P(offset));
    transfer t = {.self = self, .io = rb_io_get_io(io), .buffer = buffer, .writing = writing, .token = Qnil};
    t.minimum = NUM2SIZET(minimum); t.offset = NIL_P(offset) ? 0 : NUM2SIZET(offset);
    if (coerces) fs_check_fiber(self);
    t.fd = rb_io_descriptor(t.io);
#if RUBY_IO_BUFFER_VERSION >= 3
    rb_io_buffer_get_bytes(buffer, &t.base, &t.size);
#else
    enum rb_io_buffer_flags flags = rb_io_buffer_get_bytes(buffer, &t.base, &t.size);
#endif
    if (!writing) rb_io_buffer_get_bytes_for_writing(buffer, &t.base, &t.size);
    if (t.offset > t.size || t.minimum > t.size - t.offset) rb_raise(rb_eArgError, "length and offset exceed buffer size");
#if RUBY_FIBER_SCHEDULER_VERSION >= 4
    // Ruby 4.1 requests one transfer bounded by length, not a minimum byte count.
    t.size = t.offset + t.minimum;
    t.minimum = t.minimum ? 1 : 0;
#endif
#ifdef MSG_DONTWAIT
    if (writing && t.size > t.offset) {
        int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        ssize_t count = send(t.fd, (char *)t.base + t.offset, t.size - t.offset, flags);
        if (count >= 0 && (size_t)count >= t.minimum) {
            VALUE result = fs_checkpoint(self, SIZET2NUM((size_t)count));
            RB_GC_GUARD(t.io); RB_GC_GUARD(buffer);
            return result;
        }
        if (count > 0) {
            // Continue a partial write without transmitting its prefix twice.
            t.offset += (size_t)count; t.minimum -= (size_t)count;
            t.initial = (size_t)count;
        } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ENOTSOCK) {
            return fs_checkpoint(self, INT2NUM(-errno));
        }
    }
#endif
    t.serial = fs_get(self)->suspensions;
#if RUBY_IO_BUFFER_VERSION >= 3
    // Locks now reference the backing allocation. Own one reference even when
    // Ruby or another buffer view already holds a lock, and release only ours.
    rb_io_buffer_lock(buffer); t.unlock = 1;
#else
    if (!(flags & RB_IO_BUFFER_LOCKED)) { rb_io_buffer_lock(buffer); t.unlock = 1; }
#endif
    VALUE result = rb_ensure(transfer_locked, (VALUE)&t, transfer_cleanup, (VALUE)&t);
    if (t.initial) result = NUM2LONG(result) < 0 ? SIZET2NUM(t.initial) : SIZET2NUM(t.initial + NUM2SIZET(result));
    if (t.serial == fs_get(self)->suspensions) fs_checkpoint(self, result);
    RB_GC_GUARD(t.io); RB_GC_GUARD(buffer);
    return result;
}

// Handle Ruby's io_read hook using the shared transfer code.
static VALUE read_io(int argc, VALUE *argv, VALUE self) { return transfer_io(argc, argv, self, 0); }

// Handle Ruby's io_write hook using the shared transfer code.
static VALUE write_io(int argc, VALUE *argv, VALUE self) { return transfer_io(argc, argv, self, 1); }
#if RUBY_API_VERSION_MAJOR >= 4

// Handle a descriptor Ruby has handed to the scheduler for closing.
// Wake its waiters with an error and retire its registration before closing it,
// so a new IO can safely reuse the descriptor number.
static VALUE close_io(VALUE self, VALUE descriptor) {
    rb_funcall(self, rb_intern("check_owner"), 0);
    int fd = NUM2INT(descriptor); fs_state *s = fs_get(self); st_data_t entry;
    if (st_lookup(s->regs, fd, &entry)) {
        fs_reg *reg = (fs_reg *)entry;
        VALUE error = rb_exc_new_cstr(rb_eIOError, "stream closed while waiting");
        for (fs_watch *w = reg->watches; w; w = w->next_reg)
            rb_funcall(self, rb_intern("interrupt_wait"), 2, w->wait->token, error);
        fs_driver_update(s, reg, 0);
        st_data_t key = fd; st_delete(s->regs, &key, NULL);
        if (reg->watches) {
            st_insert(s->retired_regs, (st_data_t)reg, (st_data_t)reg);
            reg->fd = -1;
        } else {
            st_data_t generation = reg->generation;
            st_delete(s->generations, &generation, NULL);
            if (reg->poll_events) s->polling_regs--;
            xfree(reg);
        }
        // New fd ownership receives a new registration generation.
    }
    // CRuby 4.0 calls this hook after flushing and handing ownership of the fd
    // to the scheduler. Do not retry close(EINTR): the number may already be reused.
    if (close(fd) < 0 && errno != EINTR) rb_sys_fail("scheduler close");
    return Qtrue;
}
#endif

// Keep the socket class alive and attach the supported IO hooks to the scheduler.
void fs_init_io(VALUE klass) {
    rb_require("socket");
    socket_class = rb_const_get(rb_cObject, rb_intern("BasicSocket"));
    rb_global_variable(&socket_class);
    rb_define_method(klass, "io_read", read_io, -1);
    rb_define_method(klass, "io_write", write_io, -1);
    rb_define_method(klass, "io_wait", fs_io_wait, -1);
#if RUBY_API_VERSION_MAJOR >= 4
    rb_define_method(klass, "io_close", close_io, 1);
#endif
}
