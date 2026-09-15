# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Module holding abstract versions of classes that have multiple public implementations.
  #
  # Subclasses of these can be found under the following namespaces:
  # * {Farce} - for Ractor-shareable implementations
  # * {Farce::Local} - implementations scoped by Ractor/Thread/Fiber/etc
  # * {Farce::Strict} - for Ractor-shareable implementations accepting only shareable values
  # * {Farce::Unshared} - for Ractor-unshareable implementations
  # * {Farce::Unsafe} – for implementations that are not thread-safe
  module Abstract
    include Internal::Autoloads
  end
end
