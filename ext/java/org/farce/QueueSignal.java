package org.farce;

import java.util.concurrent.Phaser;

/** Thread-only notification and queue commit can execute without Ruby callbacks. */
public class QueueSignal extends Phaser {
    private int schedulerWaiters;

    public QueueSignal() { super(1); }

    public synchronized int broadcastThreads() {
        int previous = arrive();
        return previous == Integer.MAX_VALUE ? 0 : previous + 1;
    }

    // Registration and commits use the SAME monitor. A new waiter can never
    // register between the zero-waiter check and the phase advance/commit.
    public synchronized void beginSchedulerWait() { schedulerWaiters++; }

    public synchronized void endSchedulerWait() { schedulerWaiters--; }

    public synchronized boolean commitWithoutFiberWaiters(Runnable operation) {
        if (schedulerWaiters != 0) return false;
        broadcastThreads();
        operation.run();
        return true;
    }
}
