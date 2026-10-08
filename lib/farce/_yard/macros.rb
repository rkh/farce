# @!macro unsafe
#   @note
#     Instances of this class are **not thread-safe** and should not be shared concurrently.
#     This does not just apply to Ractors, but also Threads and possibly Fibers.
#
#     Only use them if you are absolutely certain of this and they do not leave a tightly controlled scope.
#     They can provide a memory or performance advantage over their thread-safe counterparts, so they
#     might be useful for hot path optimizations.
#
#     Concurrent access, especially modifications, may corrupt the internal state of the object.

# @!macro modes
#   Valid modes are:
#   * `:copy` - The value will be copied between Ractors. This is the default mode.
#   * `:make_shareable` - The value will be made Ractor-shareable using {Ractor.make_shareable}.
#   * `:move` - The value will be moved between Ractors. This saves memory compared to copying, and supports values
#     that can't be copied but moved (like IO objects). However, the value will no longer be accessible on the Ractor
#     that pushed it.
#   * `:mutable` - A {Farce::Mutable} instance will be created for the value. This isn't done recursively and thus will fail for nested unshareable values.
#   * `:local` - The value will be kept local to the Ractor that pushed it. Another ractor trying to receive it will
#     get an error. Useful for usage contained within a single Ractor.
#   * `:proxy` - The value will be wrapped in a `Farce::Proxy` that executes calls in the original Ractor.
#   * `:raise` - An error will be raised if the value is not Ractor-shareable. Useful for enforcing shareability.
#   * `:dedup` - The value will be deduplicated using {Farce.dedup}, then made Ractor-shareable.
#     This may update and freeze the original. Already-shareable values pass through unchanged.
#   * `:shareable_copy` - The value will be copied and the copy will be made Ractor-shareable.

# @!macro scopes
#   Valid scopes are:
#   * `:ractor` - The value is shared by all threads within the same Ractor.
#   * `:thread_group` - The value is shared by all threads within the same thread group.
#   * `:thread` - The value is shared by all fibers within the same thread.
#   * `:fiber_storage` - The value is shared by all fibers using the same storage.
#     Unless explicitly specified, storage is inherited from the parent fiber for blocking fibers,
#     but not for non-blocking fibers (such as those created by {Scheduler#schedule}).
#   * `:fiber` - Each fiber has its own independent value.

# @!macro key_normalization
#   @param normalize_keys [Symbol, Proc, Hash, Farce::Abstract::Map, nil]
#     Converts incoming keys to their canonical stored form:
#     * If a `Symbol` is provided, it will be used as a method name to call on each key.
#     * If a `Proc` is provided, it will be called with each key and should return the normalized key.
#     * If a `Hash` or {Farce::Abstract::Map Map} is provided, it will be used to look up the normalized key for each incoming key.

# @!macro active_support
#   @note This methods is only available if ActiveSupport has been loaded.
