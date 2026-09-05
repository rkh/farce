package org.farce;

import java.util.Comparator;

/** Keeps ordinary float comparisons inside the JVM's TreeMap traversal. */
public final class PriorityKey {
    // An opaque Ruby wrapper preserves String subclasses and comparison state
    // across both JRuby's and TruffleRuby's automatic Java conversions.
    private final Object rubyKey;
    private final boolean floating;
    private final double number;
    private final boolean snapshot;

    public PriorityKey(Object rubyKey, boolean floating, double number) {
        this(rubyKey, floating, number, false);
    }

    public PriorityKey(Object rubyKey, boolean floating, double number, boolean snapshot) {
        this.rubyKey = rubyKey;
        this.floating = floating;
        this.number = number;
        this.snapshot = snapshot;
    }

    public boolean requiresSnapshot() { return snapshot; }

    public Object getRubyKey() {
        return rubyKey;
    }

    public static Comparator<PriorityKey> comparator(Comparator<Object> fallback) {
        return (left, right) -> {
            // TreeMap checks its first key against itself. Ruby containers do
            // not invoke the priority's comparator for that insertion.
            if (left == right) return 0;
            if (left.floating && right.floating &&
                    !Double.isNaN(left.number) && !Double.isNaN(right.number)) {
                // Double.compare distinguishes signed zero; Ruby does not.
                return left.number < right.number ? -1 : left.number > right.number ? 1 : 0;
            }
            // Preserve Ruby comparison failures, coercion, and mixed priorities.
            return fallback.compare(left.rubyKey, right.rubyKey);
        };
    }
}
