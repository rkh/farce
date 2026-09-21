package org.farce;

import java.math.BigInteger;
import java.util.function.BiPredicate;

/** Hash-indexed LRU/LFU storage with opaque boxed Ruby keys and values. */
public final class BoundedMap {
    private static final int INITIAL_TABLE_SIZE = 16;
    private static final Object TOMBSTONE = new Object();

    // Overflow tests compile a temporary source copy with this constant changed
    // to Long.MAX_VALUE - 1, then restore the production jar built from one.
    private static final long INITIAL_FREQUENCY = 1L;
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);
    private static final BigInteger ONE = BigInteger.ONE;

    private static class Entry {
        final Object key;
        final int hash;
        Object value;
        int slot;
        Entry previous;
        Entry following;

        Entry(Object key, Object value, int hash) {
            this.key = key;
            this.value = value;
            this.hash = hash;
        }
    }

    private static final class LFUEntry extends Entry {
        Bucket bucket;

        LFUEntry(Object key, Object value, int hash) { super(key, value, hash); }
    }

    private static final class Bucket {
        long frequency;
        BigInteger bigFrequency;
        Bucket previous;
        Bucket following;
        Entry leastRecent;
        Entry mostRecent;

        Bucket(long frequency, BigInteger bigFrequency) {
            this.frequency = frequency;
            this.bigFrequency = bigFrequency;
        }
    }

    private final boolean lfu;
    private final BiPredicate<Object, Object> equal;
    private Object[] table = new Object[INITIAL_TABLE_SIZE];
    private int size;
    private int used;
    private long maxSize;
    private Entry leastRecent;
    private Entry mostRecent;
    private Bucket leastFrequency;
    private Bucket mostFrequency;

    public BoundedMap(boolean lfu, long maxSize, BiPredicate<Object, Object> equal) {
        if (maxSize < 0) throw new IllegalArgumentException("maxSize must be non-negative");
        this.lfu = lfu;
        this.maxSize = maxSize;
        this.equal = equal;
    }

    public Object get(Object key, int hash) {
        Entry entry = find(key, hash);
        if (entry == null) return null;
        if (lfu) promoteLFU(entry);
        else promoteLRU(entry);
        return entry.value;
    }

    public Object observe(Object key, int hash) {
        Entry entry = find(key, hash);
        return entry == null ? null : entry.value;
    }

    public Object observeKey(Object key, int hash) {
        Entry entry = find(key, hash);
        return entry == null ? null : entry.key;
    }

    public Object put(Object key, Object value, int hash) {
        Entry existing = find(key, hash);
        if (existing != null) {
            if (lfu) promoteLFU(existing);
            else promoteLRU(existing);
            existing.value = value;
            return value;
        }
        if (maxSize == 0) return value;

        prepareTableForInsert();
        Entry inserted = lfu ? new LFUEntry(key, value, hash) : new Entry(key, value, hash);
        Bucket initial = null;
        if (lfu && (leastFrequency == null || !hasInitialFrequency(leastFrequency))) {
            initial = new Bucket(INITIAL_FREQUENCY, null);
        }
        Entry victim = size >= maxSize ? victim() : null;

        int slot = emptySlot(hash);
        if (table[slot] == null) used++;
        table[slot] = inserted;
        inserted.slot = slot;
        size++;
        if (lfu) {
            if (initial != null) linkBucketBefore(initial, leastFrequency);
            appendToBucket(initial == null ? leastFrequency : initial, inserted);
        } else {
            appendLRU(inserted);
        }
        if (victim != null) removeKnown(victim);
        return value;
    }

    public Object delete(Object key, int hash) {
        Entry entry = find(key, hash);
        if (entry == null) return null;
        Object value = entry.value;
        removeKnown(entry);
        return value;
    }

    public Object[] shift() {
        Entry entry = victim();
        if (entry == null) return null;
        Object[] pair = new Object[] { entry.key, entry.value };
        removeKnown(entry);
        return pair;
    }

    public long prune(long target) {
        long removed = 0;
        while (size > target) {
            removeKnown(victim());
            removed++;
        }
        return removed;
    }

    public void setMaxSize(long limit) {
        if (limit < 0) throw new IllegalArgumentException("limit must be non-negative");
        while (size > limit) removeKnown(victim());
        maxSize = limit;
    }

    public long getMaxSize() { return maxSize; }
    public long size() { return size; }
    public boolean isEmpty() { return size == 0; }

    public void clear() {
        Object[] replacement = new Object[INITIAL_TABLE_SIZE];
        table = replacement;
        size = 0;
        used = 0;
        leastRecent = mostRecent = null;
        leastFrequency = mostFrequency = null;
    }

    public Object[] snapshot() {
        if (size > Integer.MAX_VALUE / 2)
            throw new OutOfMemoryError("bounded map snapshot is too large");
        Object[] result = new Object[size * 2];
        int offset = 0;
        if (lfu) {
            for (Bucket bucket = leastFrequency; bucket != null; bucket = bucket.following) {
                for (Entry entry = bucket.leastRecent; entry != null; entry = entry.following) {
                    result[offset++] = entry.key;
                    result[offset++] = entry.value;
                }
            }
        } else {
            for (Entry entry = leastRecent; entry != null; entry = entry.following) {
                result[offset++] = entry.key;
                result[offset++] = entry.value;
            }
        }
        return result;
    }

    /** Copy storage and eviction history without invoking Ruby key callbacks. */
    public BoundedMap copy() {
        BoundedMap copy = new BoundedMap(lfu, maxSize, equal);
        copy.table = new Object[table.length];
        if (lfu) {
            for (Bucket sourceBucket = leastFrequency; sourceBucket != null; sourceBucket = sourceBucket.following) {
                Bucket bucket = new Bucket(sourceBucket.frequency, sourceBucket.bigFrequency);
                copy.linkBucketBefore(bucket, null);
                for (Entry source = sourceBucket.leastRecent; source != null; source = source.following) {
                    Entry entry = new LFUEntry(source.key, source.value, source.hash);
                    copy.insertCopiedEntry(entry);
                    copy.appendToBucket(bucket, entry);
                }
            }
        } else {
            for (Entry source = leastRecent; source != null; source = source.following) {
                Entry entry = new Entry(source.key, source.value, source.hash);
                copy.insertCopiedEntry(entry);
                copy.appendLRU(entry);
            }
        }
        return copy;
    }

    private void insertCopiedEntry(Entry entry) {
        int slot = emptySlot(entry.hash);
        table[slot] = entry;
        entry.slot = slot;
        size++;
        used++;
    }

    private Entry victim() {
        return lfu ? (leastFrequency == null ? null : leastFrequency.leastRecent) : leastRecent;
    }

    private Entry find(Object key, int hash) {
        int mask = table.length - 1;
        int slot = spread(hash) & mask;
        while (true) {
            Object item = table[slot];
            if (item == null) return null;
            if (item != TOMBSTONE) {
                Entry entry = (Entry)item;
                if (entry.hash == hash && equal.test(entry.key, key)) return entry;
            }
            slot = (slot + 1) & mask;
        }
    }

    private int emptySlot(int hash) {
        int mask = table.length - 1;
        int slot = spread(hash) & mask;
        int tombstone = -1;
        while (true) {
            Object item = table[slot];
            if (item == null) return tombstone < 0 ? slot : tombstone;
            if (item == TOMBSTONE && tombstone < 0) tombstone = slot;
            slot = (slot + 1) & mask;
        }
    }

    private static int spread(int hash) { return hash ^ (hash >>> 16); }

    private void prepareTableForInsert() {
        int threshold = table.length - table.length / 3;
        if (used + 1 <= threshold) return;

        int desired = size + 1 <= threshold ? table.length : checkedDouble(table.length);
        rebuild(desired);
    }

    private static int checkedDouble(int length) {
        if (length >= (1 << 30)) throw new OutOfMemoryError("bounded map index is too large");
        return length << 1;
    }

    private void rebuild(int capacity) {
        Object[] replacement = new Object[capacity];
        for (Object item : table) {
            if (item == null || item == TOMBSTONE) continue;
            Entry entry = (Entry)item;
            int mask = replacement.length - 1;
            int slot = spread(entry.hash) & mask;
            while (replacement[slot] != null) slot = (slot + 1) & mask;
            replacement[slot] = entry;
            entry.slot = slot;
        }
        table = replacement;
        used = size;
    }

    private void removeKnown(Entry entry) {
        table[entry.slot] = TOMBSTONE;
        size--;
        if (lfu) unlinkLFU(entry);
        else unlinkLRU(entry);
        entry.previous = entry.following = null;
        if (lfu) ((LFUEntry)entry).bucket = null;
    }

    private void appendLRU(Entry entry) {
        entry.previous = mostRecent;
        if (mostRecent == null) leastRecent = entry;
        else mostRecent.following = entry;
        mostRecent = entry;
    }

    private void unlinkLRU(Entry entry) {
        if (entry.previous == null) leastRecent = entry.following;
        else entry.previous.following = entry.following;
        if (entry.following == null) mostRecent = entry.previous;
        else entry.following.previous = entry.previous;
    }

    private void promoteLRU(Entry entry) {
        if (entry == mostRecent) return;
        unlinkLRU(entry);
        entry.previous = entry.following = null;
        appendLRU(entry);
    }

    private static boolean hasInitialFrequency(Bucket bucket) {
        return bucket.bigFrequency == null && bucket.frequency == INITIAL_FREQUENCY;
    }

    private static boolean sameFrequency(Bucket bucket, long frequency, BigInteger bigFrequency) {
        if (bucket.bigFrequency == null || bigFrequency == null)
            return bucket.bigFrequency == null && bigFrequency == null && bucket.frequency == frequency;
        return bucket.bigFrequency.equals(bigFrequency);
    }

    private void promoteLFU(Entry entry) {
        Bucket current = ((LFUEntry)entry).bucket;
        Bucket following = current.following;
        long frequency = 0;
        BigInteger bigFrequency = null;
        if (current.bigFrequency != null) bigFrequency = current.bigFrequency.add(ONE);
        else if (current.frequency == Long.MAX_VALUE) bigFrequency = LONG_MAX.add(ONE);
        else frequency = current.frequency + 1;

        if (following != null && sameFrequency(following, frequency, bigFrequency)) {
            unlinkFromBucket(current, entry);
            appendToBucket(following, entry);
            return;
        }
        if (current.leastRecent == entry && current.mostRecent == entry) {
            current.frequency = frequency;
            current.bigFrequency = bigFrequency;
            return;
        }

        Bucket destination = new Bucket(frequency, bigFrequency);
        linkBucketAfter(destination, current);
        unlinkFromBucket(current, entry);
        appendToBucket(destination, entry);
    }

    private void appendToBucket(Bucket bucket, Entry entry) {
        ((LFUEntry)entry).bucket = bucket;
        entry.previous = bucket.mostRecent;
        entry.following = null;
        if (bucket.mostRecent == null) bucket.leastRecent = entry;
        else bucket.mostRecent.following = entry;
        bucket.mostRecent = entry;
    }

    private void unlinkLFU(Entry entry) { unlinkFromBucket(((LFUEntry)entry).bucket, entry); }

    private void unlinkFromBucket(Bucket bucket, Entry entry) {
        if (entry.previous == null) bucket.leastRecent = entry.following;
        else entry.previous.following = entry.following;
        if (entry.following == null) bucket.mostRecent = entry.previous;
        else entry.following.previous = entry.previous;
        entry.previous = entry.following = null;
        if (bucket.leastRecent == null) unlinkBucket(bucket);
    }

    private void linkBucketBefore(Bucket bucket, Bucket following) {
        bucket.following = following;
        if (following == null) {
            bucket.previous = mostFrequency;
            if (mostFrequency == null) leastFrequency = bucket;
            else mostFrequency.following = bucket;
            mostFrequency = bucket;
        } else {
            bucket.previous = following.previous;
            if (following.previous == null) leastFrequency = bucket;
            else following.previous.following = bucket;
            following.previous = bucket;
        }
    }

    private void linkBucketAfter(Bucket bucket, Bucket previous) {
        bucket.previous = previous;
        bucket.following = previous.following;
        if (previous.following == null) mostFrequency = bucket;
        else previous.following.previous = bucket;
        previous.following = bucket;
    }

    private void unlinkBucket(Bucket bucket) {
        if (bucket.previous == null) leastFrequency = bucket.following;
        else bucket.previous.following = bucket.following;
        if (bucket.following == null) mostFrequency = bucket.previous;
        else bucket.following.previous = bucket.previous;
        bucket.previous = bucket.following = null;
    }
}
