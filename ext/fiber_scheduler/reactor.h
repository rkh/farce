#ifndef FARCE_FIBER_REACTOR_H
#define FARCE_FIBER_REACTOR_H
#include <ruby.h>
#include <ruby/io.h>
#include <ruby/io/buffer.h>
#include <ruby/thread.h>
#include <ruby/st.h>
#include <pthread.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#if defined(FARCE_HAVE_LIBURING)
#include <liburing.h>
#define FARCE_URING 1
#endif
#ifdef HAVE_SYS_EVENT_H
#include <sys/event.h>
#endif
#define FS_READ 1
#define FS_PRI 2
#define FS_WRITE 4
#define FS_EVENTS 1024
#define FS_RECEIVE (UINT64_C(1) << 63)
#define FS_SLOT_BITS 20
#define FS_SLOT_MASK ((1U << FS_SLOT_BITS) - 1)

typedef struct fs_admission fs_admission;
struct fs_admission { VALUE parent, child; fs_admission *previous; };
typedef struct fs_wait fs_wait;
typedef struct { fs_wait *wait; uint64_t generation; uint32_t next_free; } fs_slot;
typedef struct fs_reg fs_reg;
typedef struct fs_watch fs_watch;
struct fs_watch {
    fs_wait *wait;
    fs_reg *reg;
    fs_watch *next_reg, *next_wait;
    int events, group;
    long index;
};
struct fs_reg {
    int fd, events, poll_events;
    uint64_t generation;
    fs_watch *watches;
};
struct fs_wait {
    VALUE token, fiber, value, error, groups, ios;
    uint32_t slot;
    int status, events, selected, queued, native_error, receive_pending;
    fs_wait *ready_next, *ready_prev;
    fs_watch *watches;
    fs_watch first_watch;
};
typedef struct { uint64_t generation; int events, error; } fs_event;
typedef struct {
    VALUE owner, root, active, backend, fallback;
    fs_wait *ready_head, *ready_tail;
    fs_admission *admission;
    int dispatch_left, stopping, closing, policy_pending, allow_poll;
    st_table *fibers, *regs, *generations, *retired_regs;
    fs_slot *slots;
    uint32_t slot_count, slot_capacity, first_free;
    size_t pending;
    uint64_t serial, generation, suspensions;
    unsigned immediate;
    int selected_pending, receive_disabled;
    int driver, descriptor, wake[2], closed;
    pthread_mutex_t wake_mutex;
#ifdef FARCE_URING
    struct io_uring ring;
    int ring_live;
#endif
#ifdef HAVE_SYS_EVENT_H
    struct kevent *changes;
    int change_count, change_capacity;
#endif
    fs_event events[FS_EVENTS];
    double timeout, close_check_at;
    int event_count, poll_error, polling_regs, ready_batches;
} fs_state;
enum { FS_EPOLL = 1, FS_KQUEUE, FS_URING_DRIVER };
extern const rb_data_type_t fs_type;
static inline fs_state *fs_get(VALUE self) {
    fs_state *s; TypedData_Get_Struct(self, fs_state, &fs_type, s); return s;
}
int fs_driver_init(fs_state *s, int driver);
int fs_driver_update(fs_state *s, fs_reg *reg, int events);
int fs_driver_receive(fs_state *s, fs_wait *w, int fd, void *buffer, size_t size);
void fs_cancel_receive(VALUE self, fs_wait *w);
void fs_driver_close(fs_state *s);
void *fs_driver_poll(void *data);
void fs_check_fiber(VALUE self);
VALUE fs_checkpoint(VALUE self, VALUE value);
VALUE fs_arm(VALUE self);
VALUE fs_arm_checked(VALUE self);
VALUE fs_suspend(VALUE self, VALUE token);
VALUE fs_park(VALUE self, VALUE token);
VALUE fs_retire(VALUE self, VALUE token);
VALUE fs_resume(VALUE self, VALUE token, VALUE value, VALUE error);
void fs_watch_io(fs_state *s, fs_wait *wait, int fd, int events, int group, long index);
fs_wait *fs_lookup(fs_state *s, VALUE token);
VALUE fs_io_wait(int argc, VALUE *argv, VALUE self);
void fs_init_io(VALUE klass);
#endif
