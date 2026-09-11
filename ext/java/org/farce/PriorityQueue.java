package org.farce;

import java.util.Comparator;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.BiPredicate;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import java.util.function.Function;

/** Ordered FIFO buckets with opaque Ruby values and transactional callbacks. */
public final class PriorityQueue {
    public static final class Failure extends RuntimeException {
        private final int code;
        Failure(int code, String message) { super(message); this.code = code; }
        public int getCode() { return code; }
    }

    private static final class Bucket {
        Entry head;
        Entry tail;
        int size;
        HashMap<Object, Entry> identities;
    }

    private static class Entry {
        final Object value;
        Entry previous;
        Entry next;
        Object token;
        Entry identityPrevious;
        Entry identityNext;
        boolean committed;
        Entry(Object value) { this.value = value; }
    }

    private static final class TrackedEntry extends Entry {
        final long enqueuedAt;
        TrackedEntry agePrevious;
        TrackedEntry ageNext;
        TrackedEntry(Object value) { super(value); enqueuedAt = System.nanoTime(); }
    }

    private final ReentrantLock lock = new ReentrantLock();
    private final TreeMap<PriorityKey, Bucket> tree;
    private final Function<PriorityKey, PriorityKey> snapshot;
    private final Function<Object, Object> identity;
    private final BiPredicate<Object, Object> equal;
    private final BiPredicate<Object, Object> identical;
    private final BiPredicate<Object, Object> match;
    private final Consumer<Runnable> committer;
    private final QueueSignal signal;
    private final BooleanSupplier scheduled;
    private final long capacity;
    private final boolean trackAge;
    private long size;
    private long generation;
    private TrackedEntry ageHead;
    private TrackedEntry ageTail;
    private boolean sealed;
    private boolean closed;

    public PriorityQueue(Comparator<PriorityKey> comparator,
                         Function<PriorityKey, PriorityKey> snapshot,
                         Function<Object, Object> identity,
                         BiPredicate<Object, Object> equal,
                         BiPredicate<Object, Object> identical,
                         BiPredicate<Object, Object> match,
                         Consumer<Runnable> committer,
                         BooleanSupplier scheduled, long capacity, QueueSignal signal,
                         boolean trackAge) {
        this.tree = new TreeMap<>(comparator);
        this.snapshot = snapshot;
        this.identity = identity;
        this.equal = equal;
        this.identical = identical;
        this.match = match;
        this.committer = committer;
        this.signal = signal;
        this.scheduled = scheduled;
        this.capacity = capacity;
        this.trackAge = trackAge;
    }

    private void enter() {
        if (lock.isHeldByCurrentThread())
            throw new Failure(1, "recursive priority queue access");
        if (!lock.tryLock()) {
            if (scheduled.getAsBoolean())
                throw new Failure(3, "shared JVM container contention cannot block a scheduled Fiber");
            lock.lock();
        }
    }

    private void checkPushOpen() {
        if (closed) throw new Failure(2, "queue is closed");
        if (sealed) throw new Failure(4, "queue is sealed");
    }

    private void checkReadOpen() {
        if (closed) throw new Failure(2, "queue is closed");
    }

    private void commit(Runnable operation) {
        if (signal != null && signal.commitWithoutFiberWaiters(operation)) return;
        if (committer == null) operation.run();
        else committer.accept(operation);
    }

    // Construct keys inside Java to avoid allocating a Ruby Java-proxy per key.
    public boolean pushFloat(double priority, Object rubyPriority, Object value) {
        return push(new PriorityKey(rubyPriority, true, priority), value);
    }

    public Object readBefore(double cutoff, Object rubyCutoff) {
        return read(0, false, new PriorityKey(rubyCutoff, true, cutoff));
    }

    public boolean push(PriorityKey query, Object value) {
        enter();
        Bucket candidate = null;
        Bucket bucket = null;
        Entry entry = null;
        try {
            checkPushOpen();
            if (capacity > 0 && size >= capacity) return false;
            bucket = tree.get(query);
            if (bucket == null) {
                PriorityKey key = query.requiresSnapshot() ? snapshot.apply(query) : query;
                candidate = new Bucket();
                Bucket existing = tree.putIfAbsent(key, candidate);
                bucket = existing == null ? candidate : existing;
            }
            entry = trackAge ? new TrackedEntry(value) : new Entry(value);
            if (bucket.identities != null) addIdentity(bucket.identities, entry);
            Bucket target = bucket;
            Entry added = entry;
            commit(() -> {
                added.previous = target.tail;
                if (target.tail == null) target.head = added;
                else target.tail.next = added;
                target.tail = added;
                target.size++;
                size++;
                trackPush(added);
                added.committed = true;
            });
            return true;
        } finally {
            if (entry == null || !entry.committed) {
                if (entry != null && entry.identityNext != null) discardIdentity(bucket.identities, entry);
                if (candidate != null && candidate.size == 0) removeEmpty(candidate);
            }
            lock.unlock();
        }
    }

    private void removeEmpty(Bucket bucket) {
        Iterator<Bucket> iterator = tree.values().iterator();
        while (iterator.hasNext()) {
            if (iterator.next() == bucket) { iterator.remove(); return; }
        }
    }

    private Iterator<Map.Entry<PriorityKey, Bucket>> iterator(boolean last) {
        return (last ? tree.descendingMap() : tree).entrySet().iterator();
    }

    // kind: 0 = pop, 1 = peek, 2 = priority. Null cutoff means unbounded.
    public Object read(int kind, boolean last, PriorityKey cutoff) {
        enter();
        try {
            checkReadOpen();
            Iterator<Map.Entry<PriorityKey, Bucket>> iterator = iterator(last);
            if (!iterator.hasNext()) return null;
            Map.Entry<PriorityKey, Bucket> item = iterator.next();
            if (kind == 2) return item.getKey().getRubyKey();
            if (cutoff != null && tree.comparator().compare(item.getKey(), cutoff) > 0) return null;
            Bucket bucket = item.getValue();
            Entry entry = bucket.head;
            if (kind == 1) return entry.value;
            commit(() -> {
                unlink(bucket, entry);
                if (bucket.size == 0) iterator.remove();
            });
            return entry.value;
        } finally { lock.unlock(); }
    }

    // kind: 0 = stored == requested, 1 = identity, 2 = requested === stored.
    public boolean removeValue(PriorityKey key, Object value, int kind) {
        enter();
        try {
            checkReadOpen();
            Bucket bucket = tree.get(key);
            if (bucket == null) return false;
            Entry found = null;
            if (kind == 1 && bucket.size >= 32 && bucket.identities == null) buildIdentities(bucket);
            if (kind == 1 && bucket.identities != null) {
                Entry head = bucket.identities.get(identity.apply(value));
                if (head != null && identical.test(head.value, value)) found = head;
            } else {
                BiPredicate<Object, Object> predicate = kind == 1 ? identical : kind == 2 ? match : equal;
                for (Entry entry = bucket.head; entry != null; entry = entry.next) {
                    if (predicate.test(entry.value, value)) { found = entry; break; }
                }
            }
            if (found == null) return false;
            Iterator<Map.Entry<PriorityKey, Bucket>> removal = null;
            if (bucket.size == 1) {
                removal = tree.tailMap(key, true).entrySet().iterator();
                if (!removal.hasNext() || removal.next().getValue() != bucket)
                    throw new IllegalStateException("priority map lost its bucket");
            }
            Entry selected = found;
            Iterator<Map.Entry<PriorityKey, Bucket>> positioned = removal;
            commit(() -> {
                unlink(bucket, selected);
                if (positioned != null) positioned.remove();
            });
            return true;
        } finally { lock.unlock(); }
    }

    private void unlink(Bucket bucket, Entry entry) {
        if (entry.previous == null) bucket.head = entry.next;
        else entry.previous.next = entry.next;
        if (entry.next == null) bucket.tail = entry.previous;
        else entry.next.previous = entry.previous;
        entry.previous = entry.next = null;
        if (bucket.identities != null) discardIdentity(bucket.identities, entry);
        bucket.size--;
        size--;
        trackRemove(entry);
        if (sealed && size == 0) closed = true;
    }

    private void trackPush(Entry entry) {
        if (!trackAge) return;
        TrackedEntry tracked = (TrackedEntry)entry;
        tracked.agePrevious = ageTail;
        if (ageTail == null) ageHead = tracked;
        else ageTail.ageNext = tracked;
        ageTail = tracked;
        generation++;
    }

    private void trackRemove(Entry entry) {
        if (!trackAge) return;
        TrackedEntry tracked = (TrackedEntry)entry;
        if (tracked.agePrevious == null) ageHead = tracked.ageNext;
        else tracked.agePrevious.ageNext = tracked.ageNext;
        if (tracked.ageNext == null) ageTail = tracked.agePrevious;
        else tracked.ageNext.agePrevious = tracked.agePrevious;
        generation++;
    }

    // Circular identity FIFOs need no separate slot allocation and retain no dead entries.
    private void addIdentity(HashMap<Object, Entry> index, Entry entry) {
        Object token = identity.apply(entry.value);
        Entry head = index.get(token);
        entry.token = token;
        if (head == null) {
            index.put(token, entry);
            entry.identityNext = entry.identityPrevious = entry;
        } else {
            Entry tail = head.identityPrevious;
            entry.identityNext = head;
            entry.identityPrevious = tail;
            tail.identityNext = head.identityPrevious = entry;
        }
    }

    private void discardIdentity(HashMap<Object, Entry> index, Entry entry) {
        if (entry.identityNext == entry) index.remove(entry.token);
        else {
            entry.identityPrevious.identityNext = entry.identityNext;
            entry.identityNext.identityPrevious = entry.identityPrevious;
            if (index.get(entry.token) == entry) index.put(entry.token, entry.identityNext);
        }
        entry.token = null;
        entry.identityNext = entry.identityPrevious = null;
    }

    private void buildIdentities(Bucket bucket) {
        HashMap<Object, Entry> index = new HashMap<>();
        boolean completed = false;
        try {
            for (Entry entry = bucket.head; entry != null; entry = entry.next) addIdentity(index, entry);
            bucket.identities = index;
            completed = true;
        } finally {
            if (!completed) {
                for (Entry entry = bucket.head; entry != null; entry = entry.next) {
                    entry.token = null;
                    entry.identityNext = entry.identityPrevious = null;
                }
            }
        }
    }

    public long size() {
        enter();
        try { return size; } finally { lock.unlock(); }
    }

    public boolean isClosed() {
        enter();
        try { return closed; } finally { lock.unlock(); }
    }

    public boolean isSealed() {
        enter();
        try { return sealed; } finally { lock.unlock(); }
    }

    public boolean isAgeTracking() { return trackAge; }

    public Long generation() {
        if (!trackAge) return null;
        enter();
        try { return generation; } finally { lock.unlock(); }
    }

    public Double oldestEnqueuedAt() {
        if (!trackAge) return null;
        enter();
        try { return ageHead == null ? null : ageHead.enqueuedAt / 1_000_000_000.0; }
        finally { lock.unlock(); }
    }

    public Double oldestAge() {
        if (!trackAge) return null;
        enter();
        try { return ageHead == null ? null : (System.nanoTime() - ageHead.enqueuedAt) / 1_000_000_000.0; }
        finally { lock.unlock(); }
    }

    public void clear() {
        enter();
        try { commit(() -> {
            tree.clear();
            if (trackAge && size > 0) generation++;
            size = 0;
            ageHead = ageTail = null;
            if (sealed) closed = true;
        }); }
        finally { lock.unlock(); }
    }

    public void seal() {
        enter();
        try { commit(() -> {
            if (!sealed && trackAge) generation++;
            sealed = true;
            if (size == 0) closed = true;
        }); }
        finally { lock.unlock(); }
    }

    public void close() {
        enter();
        try { commit(() -> {
            if (!closed && trackAge) generation++;
            sealed = true;
            closed = true;
        }); }
        finally { lock.unlock(); }
    }
}
