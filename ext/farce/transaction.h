#ifndef FARCE_TRANSACTION_H
#define FARCE_TRANSACTION_H

#include "containers.h"

/* Only transaction entry points use this protocol. Existing container access
 * paths and layouts do not consult transaction state. Callbacks run with all
 * participant mutexes held and must not allocate Ruby objects or call Ruby. */
typedef struct farce_transaction_entry farce_transaction_entry_t;
typedef struct {
    bool (*valid)(farce_transaction_entry_t *);
    void (*apply)(farce_transaction_entry_t *);
    void (*notify)(farce_transaction_entry_t *);
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
