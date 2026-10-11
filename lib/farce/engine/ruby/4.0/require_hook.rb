# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Ruby 4.0 prepends its Ractor-aware require to Kernel when Ractors activate.
# A later Kernel alias captures that wrapper and loses its super target.
# Keep the original implementation above Object so aliases capture Kernel's
# underlying require while secondary Ractors still use Ruby's loader service.
ractor_require = Kernel.ancestors.find { it.name == "<RactorRequire>" }
if ractor_require
  replacement = Module.new
  replacement.set_temporary_name("<FarceRactorRequire>")
  replacement.define_method(:require, ractor_require.instance_method(:require))
  replacement.send(:private, :require)
  Object.prepend(replacement)
  ractor_require.remove_method(:require)
end
