#ifndef RACTOR_CONTAINERS_H
#define RACTOR_CONTAINERS_H

#include "ruby.h"
#include "ruby/ractor.h"
#include "ruby/thread.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#ifndef _WIN32
#include <sys/time.h>
#endif

void containers_check_shareable(VALUE value);
bool containers_strict_bool(VALUE value, const char *name);
void containers_finish_initialization(VALUE self);
RBIMPL_ATTR_NORETURN()
void containers_raise_key_error(VALUE receiver, VALUE key);

void containers_init_atom(VALUE namespace);
void containers_init_counter(VALUE namespace);
void containers_init_exchanger(VALUE namespace);
void containers_init_flag(VALUE namespace);
void containers_init_lock(VALUE namespace);
void containers_init_map(VALUE namespace);
void containers_init_priority_queue(VALUE namespace);
void containers_init_queue(VALUE namespace);
void containers_init_signal(VALUE namespace);

typedef struct containers_unshared_signal containers_unshared_signal_t;
containers_unshared_signal_t *containers_unshared_signal_get_if_exact(VALUE signal);
bool containers_unshared_fiber_io(VALUE mode);
bool containers_unshared_signal_uses_fiber_io(VALUE signal);
bool containers_unshared_signal_has_waiters(containers_unshared_signal_t *signal);
void containers_unshared_signal_notify(containers_unshared_signal_t *signal);
void containers_init_unshared_signal(VALUE namespace);
void containers_init_unshareable(VALUE namespace);
void containers_init_vector(VALUE namespace);
void containers_init_weak_maps(VALUE namespace);
void containers_init_tree_maps(VALUE namespace);

#endif
