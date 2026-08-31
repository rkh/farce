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
