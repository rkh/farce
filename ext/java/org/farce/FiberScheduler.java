package org.farce;

import java.io.IOException;
import java.nio.channels.SelectableChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.util.HashMap;
import java.util.Map;
import org.jruby.Ruby;
import org.jruby.RubyArray;
import org.jruby.RubyClass;
import org.jruby.RubyIO;
import org.jruby.RubyIOBuffer;
import java.nio.ByteBuffer;
import java.lang.reflect.Field;
import org.jruby.RubyModule;
import org.jruby.RubyObject;
import org.jruby.RubyThread;
import org.jruby.anno.JRubyMethod;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.io.SelectExecutor;

/** The public Ruby subclass itself owns this Java state. Channels remain Ruby-owned. */
public final class FiberScheduler extends RubyObject {
    private Selector selector;
    private RubyThread owner;
    private long compatibilityPolls;

    public FiberScheduler(Ruby runtime, RubyClass klass) { super(runtime, klass); }

    public static void load(Ruby runtime) {
        RubyModule internal = (RubyModule) runtime.getModule("Farce").getConstantAt("Internal");
        RubyClass klass = internal.defineClassUnder("FiberScheduler", runtime.getObject(), FiberScheduler::new);
        klass.defineAnnotatedMethods(FiberScheduler.class);
    }

    @JRubyMethod(name = "nio_initialize")
    public IRubyObject initializeNio(ThreadContext context) {
        if (owner != null) throw context.runtime.newRuntimeError("scheduler already initialized");
        owner = context.getThread().getFiberCurrentThread();
        try { selector = Selector.open(); }
        catch (IOException error) { throw context.runtime.newIOError(error.toString()); }
        return context.nil;
    }

    private void checkOwner(ThreadContext context) {
        if (context.getThread().getFiberCurrentThread() != owner)
            throw context.runtime.newThreadError("scheduler belongs to another thread");
    }

    private IRubyObject snapshot(ThreadContext context, RubyArray groups, Long milliseconds) {
        // This primitive is below JRuby's scheduler dispatch and preserves Ruby IO buffers.
        return new SelectExecutor(groups.entry(0), groups.entry(1), groups.entry(2), milliseconds).go(context);
    }

    @JRubyMethod(name = "nio_select", required = 2)
    public IRubyObject select(ThreadContext context, IRubyObject groupValue, IRubyObject timeout) {
        checkOwner(context);
        if (selector == null) throw context.runtime.newIOError("scheduler is closed");
        RubyArray groups = (RubyArray) groupValue;
        Long milliseconds = timeout.isNil() ? null : Math.max(0, (long)Math.ceil(timeout.convertToFloat().getDoubleValue() * 1000));
        IRubyObject immediate = snapshot(context, groups, 0L);
        if (!immediate.isNil() || (milliseconds != null && milliseconds == 0)) return immediate;
        HashMap<SelectableChannel, Integer> interests = new HashMap<>();
        boolean compatible = ((RubyArray)groups.entry(2)).isEmpty();
        for (int i = 0; i < 2; i++) {
            RubyArray list = (RubyArray)groups.entry(i);
            for (Object object : list.toJavaArray()) {
                RubyIO io = RubyIO.convertToIO(context, (IRubyObject)object);
                SelectableChannel channel = io.getOpenFileChecked().fd().chSelect;
                if (channel == null || channel.provider() != selector.provider()) { compatible = false; continue; }
                int ops = i == 0 ? SelectionKey.OP_READ : SelectionKey.OP_WRITE;
                if ((channel.validOps() & ops) == 0) { compatible = false; continue; }
                interests.merge(channel, ops, (a, b) -> a | b);
            }
        }
        if (!compatible) {
            compatibilityPolls++;
            return snapshot(context, groups, milliseconds);
        }
        try {
            for (SelectionKey key : selector.keys()) if (!interests.containsKey(key.channel())) key.cancel();
            selector.selectNow(); // acknowledge cancelled keys before re-registering
            for (Map.Entry<SelectableChannel, Integer> entry : interests.entrySet()) {
                SelectableChannel channel = entry.getKey();
                channel.configureBlocking(false);
                SelectionKey key = channel.keyFor(selector);
                if (key == null) channel.register(selector, entry.getValue());
                else key.interestOps(entry.getValue());
            }
            if (milliseconds == null) selector.select();
            else selector.select(milliseconds);
            selector.selectedKeys().clear();
            return snapshot(context, groups, 0L);
        } catch (IOException error) {
            throw context.runtime.newIOError(error.toString());
        }
    }

    @JRubyMethod(name = "nio_wakeup")
    public IRubyObject wakeup(ThreadContext context) {
        Selector current = selector;
        if (current != null) current.wakeup();
        return context.nil;
    }

    @JRubyMethod(name = "nio_destroy")
    public IRubyObject destroy(ThreadContext context) {
        if (owner != null) checkOwner(context);
        Selector current = selector;
        selector = null;
        if (current != null) try { current.close(); }
        catch (IOException error) { throw context.runtime.newIOError(error.toString()); }
        return context.nil;
    }

    // Some runtime-created hook buffers report size zero despite having storage.
    // Inspect the buffer itself so the workaround also covers patched releases.
    // Leave normal and genuinely empty buffers alone. For a malformed buffer,
    // expose only the backing ByteBuffer's remaining range without changing it.
    @JRubyMethod(name = "nio_hook_buffer", required = 1)
    public IRubyObject hookBuffer(ThreadContext context, IRubyObject value) {
        RubyIOBuffer buffer = (RubyIOBuffer)value;
        if (!buffer.locked_p(context).isTrue()) return value;
        if (buffer.size(context).convertToInteger().getLongValue() != 0) return value;
        try {
            Field field = RubyIOBuffer.class.getDeclaredField("base");
            if (!field.trySetAccessible()) throw context.runtime.newRuntimeError("Farce cannot access the JRuby hook buffer layout");
            ByteBuffer base = (ByteBuffer)field.get(buffer);
            if (base == null || !base.hasRemaining()) return value;
            int flags = buffer.readonly_p(context).isTrue() ? RubyIOBuffer.READONLY : 0;
            return RubyIOBuffer.newBuffer(context, base.slice(), base.remaining(), flags);
        } catch (ReflectiveOperationException error) {
            throw context.runtime.newRuntimeError("Farce cannot adapt the JRuby hook buffer layout: " + error);
        }
    }

    @JRubyMethod(name = "compatibility_polls")
    public IRubyObject compatibilityPolls(ThreadContext context) { return context.runtime.newFixnum(compatibilityPolls); }
}
