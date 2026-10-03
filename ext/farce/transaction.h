#ifndef FARCE_TRANSACTION_H
#define FARCE_TRANSACTION_H

#include "containers.h"

/* Callbacks run under participant state mutexes and must not allocate or call
 * Ruby. Logical reservations let a foreign commit execute with those short
 * mutexes released while ordinary access remains excluded. */
#define FARCE_TRANSACTION_RESERVED 2
typedef struct farce_transaction_entry farce_transaction_entry_t;
typedef struct {
    bool (*valid)(farce_transaction_entry_t *);
    void (*apply)(farce_transaction_entry_t *);
    void (*notify)(farce_transaction_entry_t *);
    void (*reserve)(farce_transaction_entry_t *, VALUE fiber, VALUE thread);
    void (*release)(farce_transaction_entry_t *);
} farce_transaction_ops_t;

struct farce_transaction_entry {
    VALUE source;
    VALUE working;
    void *source_data;
    void *working_data;
    pthread_mutex_t *lock;
    uint64_t version;
    bool dirty;
    bool finished;
    bool reserved;
    const farce_transaction_ops_t *ops;
};

VALUE farce_transaction_entry_new(
    VALUE source, VALUE working, void *source_data, void *working_data,
    pthread_mutex_t *lock, const farce_transaction_ops_t *ops,
    farce_transaction_entry_t **entry
);
bool farce_transaction_flag_set(VALUE flag);
void containers_init_transaction(VALUE namespace);

#endif
