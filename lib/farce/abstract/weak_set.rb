# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract A set whose elements are retained weakly.
    # Heap elements can disappear once no other strong reference remains.
    class WeakSet < Set
    end
  end
end
