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
#   * `:local` - The value will be kept local to the Ractor that pushed it. Another ractor trying to receive it will
#     get an error. Useful for usage contained within a single Ractor.
#   * `:raise` - An error will be raised if the value is not Ractor-shareable. Useful for enforcing shareability.
#   * `:shareable_copy` - The value will be copied and the copy will be made Ractor-shareable.
