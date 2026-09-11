#include "reactor.h"
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <math.h>
#ifdef HAVE_SYS_EPOLL_H
#include <sys/epoll.h>
#endif
#ifdef HAVE_SYS_EVENT_H
#include <sys/event.h>
#endif

static struct timespec relative_time(double seconds) {
    struct timespec t;
    t.tv_sec = (time_t)seconds;
    t.tv_nsec = (long)((seconds - (double)t.tv_sec) * 1e9);
    return t;
}

int fs_driver_init(fs_state *s, int driver) {
    s->driver = driver;
#ifdef HAVE_SYS_EPOLL_H
    if (driver == FS_EPOLL) {
        s->descriptor = epoll_create1(EPOLL_CLOEXEC);
        return s->descriptor < 0 ? errno : 0;
    }
#endif
#ifdef HAVE_SYS_EVENT_H
    if (driver == FS_KQUEUE) {
        s->descriptor = kqueue();
        return s->descriptor < 0 ? errno : 0;
    }
#endif
#ifdef FARCE_URING
    if (driver == FS_URING_DRIVER) {
        int result = io_uring_queue_init(1024, &s->ring, 0);
        if (result < 0) return -result;
        s->ring_live = 1;
        return 0;
    }
#endif
    return ENOSYS;
}

#ifdef FARCE_URING
static struct io_uring_sqe *sqe(fs_state *s) {
    struct io_uring_sqe *entry = io_uring_get_sqe(&s->ring);
    if (!entry) {
        int result = io_uring_submit(&s->ring);
        if (result < 0) { errno = -result; return NULL; }
        entry = io_uring_get_sqe(&s->ring);
    }
    if (!entry) errno = EBUSY;
    return entry;
}
#endif

int fs_driver_receive(fs_state *s, fs_wait *w, int fd, void *buffer, size_t size) {
#ifdef FARCE_URING
    struct io_uring_sqe *entry = sqe(s);
    if (!entry) return errno;
    io_uring_prep_recv(entry, fd, buffer, size > INT_MAX ? INT_MAX : (unsigned)size, 0);
#ifdef IORING_RECVSEND_POLL_FIRST
    entry->ioprio |= IORING_RECVSEND_POLL_FIRST;
#endif
    entry->user_data = FS_RECEIVE | NUM2ULL(w->token);
    w->receive_pending = 1;
    // Consume every queued SQE while holding the GVL, before Ruby can close or
    // reopen this fd. SQPOLL is not enabled. The kernel then owns its file ref.
    while (io_uring_sq_ready(&s->ring)) {
        int result = io_uring_submit(&s->ring);
        if (result < 0 && result != -EINTR) return -result;
    }
    return 0;
#else
    return ENOSYS;
#endif
}

int fs_driver_update(fs_state *s, fs_reg *reg, int events) {
    uint64_t previous = reg->generation;
    uint64_t generation = ++s->generation;
    int old = reg->events;
#ifdef HAVE_SYS_EPOLL_H
    if (s->driver == FS_EPOLL) {
        struct epoll_event ev = {.data.u64 = generation};
        if (events & FS_READ) ev.events |= EPOLLIN | EPOLLRDHUP;
        if (events & FS_WRITE) ev.events |= EPOLLOUT;
        if (events & FS_PRI) ev.events |= EPOLLPRI;
        int action = !events ? EPOLL_CTL_DEL : old ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
        if (epoll_ctl(s->descriptor, action, reg->fd, &ev) < 0 &&
            !(events == 0 && (errno == ENOENT || errno == EBADF))) return errno;
    }
#endif
#ifdef HAVE_SYS_EVENT_H
    if (s->driver == FS_KQUEUE) {
        struct timespec zero = {0, 0};
        for (int bit = FS_READ; bit <= FS_WRITE; bit <<= 1) {
            if (!(old & bit) && !(events & bit)) continue;
            if (reg->poll_events & bit) continue;
            if (bit != FS_PRI) {
                if (s->change_count == s->change_capacity) {
                    s->change_capacity = s->change_capacity ? s->change_capacity * 2 : 256;
                    REALLOC_N(s->changes, struct kevent, s->change_capacity);
                }
                struct kevent *change = &s->changes[s->change_count++];
                EV_SET(change, reg->fd, bit == FS_READ ? EVFILT_READ : EVFILT_WRITE,
                    events & bit ? EV_ADD | EV_ENABLE : EV_DELETE, 0, 0, (void *)(uintptr_t)generation);
                continue;
            }
            struct kevent change, result;
            EV_SET(&change, reg->fd, bit == FS_READ ? EVFILT_READ : bit == FS_WRITE ? EVFILT_WRITE : EVFILT_EXCEPT,
                (events & bit ? EV_ADD | EV_ENABLE : EV_DELETE) | EV_RECEIPT, bit == FS_PRI ? NOTE_OOB : 0, 0,
                (void *)(uintptr_t)generation);
            int count = kevent(s->descriptor, &change, 1, &result, 1, &zero);
            if (count < 0) return errno;
            // EVFILT_EXCEPT is not supported by every descriptor (e.g. pipes).
            // Retain the logical interest and snapshot it with poll instead.
            if (count && bit == FS_PRI && (events & bit) &&
                (result.data == EINVAL || result.data == ENOTSUP)) {
                reg->poll_events |= bit;
                s->polling_regs++;
                continue;
            }
            if (count && result.data && !(!(events & bit) &&
                (result.data == ENOENT || result.data == EBADF))) return (int)result.data;
        }
    }
#endif
#ifdef FARCE_URING
    if (s->driver == FS_URING_DRIVER) {
        if (old) {
            struct io_uring_sqe *entry = sqe(s);
            if (!entry) return errno;
            io_uring_prep_poll_remove(entry, previous);
            entry->user_data = 0; // cancellation acknowledgement has no storage pointer
        }
        if (events) {
            struct io_uring_sqe *entry = sqe(s);
            if (!entry) return errno;
            unsigned mask = 0;
            if (events & FS_READ) mask |= POLLIN;
            if (events & FS_WRITE) mask |= POLLOUT;
            if (events & FS_PRI) mask |= POLLPRI;
            io_uring_prep_poll_add(entry, reg->fd, mask);
            entry->user_data = generation;
        }
    }
#endif
    if (previous) { st_data_t key = previous; st_delete(s->generations, &key, NULL); }
    reg->generation = generation;
    reg->events = events;
    if (events) st_insert(s->generations, generation, (st_data_t)reg);
    return 0;
}

void *fs_driver_poll(void *data) {
    fs_state *s = data;
    s->event_count = s->poll_error = 0;
    struct timespec t = relative_time(s->timeout < 0 ? 0 : s->timeout);
#ifdef HAVE_SYS_EPOLL_H
    if (s->driver == FS_EPOLL) {
        struct epoll_event events[FS_EVENTS];
        int n;
#ifdef HAVE_EPOLL_PWAIT2
        n = epoll_pwait2(s->descriptor, events, FS_EVENTS, s->timeout < 0 ? NULL : &t, NULL);
        if (n < 0 && errno == ENOSYS)
#endif
        n = epoll_wait(s->descriptor, events, FS_EVENTS,
            s->timeout < 0 ? -1 : (int)fmin(ceil(s->timeout * 1000), INT_MAX));
        if (n < 0) { s->poll_error = errno; return NULL; }
        for (int i = 0; i < n; i++) {
            uint32_t e = events[i].events;
            int mask = 0;
            if (e & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR)) mask |= FS_READ;
            if (e & (EPOLLOUT | EPOLLHUP | EPOLLERR)) mask |= FS_WRITE;
            if (e & EPOLLPRI) mask |= FS_PRI;
            s->events[s->event_count++] = (fs_event){events[i].data.u64, mask, 0};
        }
    }
#endif
#ifdef HAVE_SYS_EVENT_H
    if (s->driver == FS_KQUEUE) {
        struct kevent events[FS_EVENTS];
        int n = kevent(s->descriptor, s->changes, s->change_count, events, FS_EVENTS, s->timeout < 0 ? NULL : &t);
        if (n < 0) { s->poll_error = errno; return NULL; }
        s->change_count = 0;
        for (int i = 0; i < n; i++)
            s->events[s->event_count++] = (fs_event){(uint64_t)(uintptr_t)events[i].udata,
                events[i].filter == EVFILT_READ ? FS_READ : events[i].filter == EVFILT_WRITE ? FS_WRITE : FS_PRI,
                events[i].flags & EV_ERROR ? (int)events[i].data : 0};
    }
#endif
#ifdef FARCE_URING
    if (s->driver == FS_URING_DRIVER) {
        int result = io_uring_submit(&s->ring);
        if (result < 0) { s->poll_error = -result; return NULL; }
        struct io_uring_cqe *cqe;
        if (s->timeout != 0 && io_uring_peek_cqe(&s->ring, &cqe) == -EAGAIN) {
            struct __kernel_timespec kt = {t.tv_sec, t.tv_nsec};
            result = s->timeout < 0 ? io_uring_wait_cqe(&s->ring, &cqe) :
                io_uring_wait_cqe_timeout(&s->ring, &cqe, &kt);
            if (result < 0 && result != -ETIME && result != -EINTR) s->poll_error = -result;
        }
        unsigned head, consumed = 0;
        io_uring_for_each_cqe(&s->ring, head, cqe) {
            if (s->event_count == FS_EVENTS) break;
            consumed++;
            if (cqe->user_data && cqe->user_data != LIBURING_UDATA_TIMEOUT) {
                int e = cqe->res, mask = 0;
                if (!(cqe->user_data & FS_RECEIVE) && e >= 0) {
                    if (e & (POLLIN | POLLHUP | POLLERR)) mask |= FS_READ;
                    if (e & (POLLOUT | POLLHUP | POLLERR)) mask |= FS_WRITE;
                    if (e & POLLPRI) mask |= FS_PRI;
                }
                s->events[s->event_count++] = (fs_event){cqe->user_data, mask,
                    cqe->user_data & FS_RECEIVE ? e : e < 0 && e != -ECANCELED ? -e : 0};
            }
        }
        io_uring_cq_advance(&s->ring, consumed);
    }
#endif
    return NULL;
}

void fs_driver_close(fs_state *s) {
#ifdef HAVE_SYS_EVENT_H
    xfree(s->changes); s->changes = NULL;
    s->change_count = s->change_capacity = 0;
#endif
#ifdef FARCE_URING
    if (s->ring_live) { io_uring_queue_exit(&s->ring); s->ring_live = 0; }
#endif
    if (s->descriptor >= 0) { close(s->descriptor); s->descriptor = -1; }
}
