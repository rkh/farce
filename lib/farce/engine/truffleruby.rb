# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    begin
      require "farce/engine/truffleruby/#{RUBY_ENGINE_VERSION}/rbtree"
      autoload :TreeMap, "farce/engine/ruby/shared/tree_map"
    rescue LoadError => e
      # simplecov:disable
      warn <<~WARNING
        Farce: Failed to load native extension for TruffleRuby #{RUBY_ENGINE_VERSION}.
        Please run `rake compile` to build the extension.
      WARNING
      raise e
      # simplecov:enable
    end

    def native_ractors? = false

    def rebind(proc, new_self, lambda)
      binding          = new_self.instance_eval { binding() }
      prefix           = "__rebind_#{proc.object_id}"
      signature        = Array.new(proc.parameters.size)
      call_signature   = []
      optional         = []
      after_optional   = []
      keyword_args     = []
      keyword_optional = []
      extra_lines      = []
      keyword_rest     = nil
      rest             = nil
      block            = nil

      proc.parameters(lambda: true).each_with_index do |(type, name), index|
        # simplecov:disable
        if name.nil? || name == :_ || name == :* || name == :** || name == "&" || name =~ /^_\d+$/
          name = :"#{prefix}_#{index}"
        end
        case type
        when :req
          signature[index] = name
          required = optional.any? ? after_optional : call_signature
          required << name
        when :opt
          signature[index] = "#{name} = UNDEFINED"
          optional << name
        when :rest
          rest = signature[index] = "*#{name}"
        when :key
          signature[index] = "#{name}: UNDEFINED"
          keyword_optional << name
        when :keyreq
          keyword_args << signature[index] = "#{name}:"
        when :keyrest
          keyword_rest = signature[index] = "**#{name}"
        when :block
          block = signature[index] = "&#{name}"
        else
          raise "unexpected parameter type: #{type}"
        end
      end
      # simplecov:enable

      if optional.any?
        extra_lines << "#{prefix}_args = []"
        call_signature << "*#{prefix}_args"
        optional.each { extra_lines << "#{prefix}_args << #{it} unless UNDEFINED.equal?(#{it})" }
      end

      call_signature << rest if rest
      call_signature += keyword_args if keyword_args.any?

      if keyword_optional.any?
        extra_lines << "#{prefix}_kwargs = {}"
        call_signature << "**#{prefix}_kwargs"
        keyword_optional.each do |arg|
          extra_lines << "#{prefix}_kwargs[#{arg.inspect}] = #{arg} unless UNDEFINED.equal?(#{arg})"
        end
      end

      call_signature << keyword_rest if keyword_rest
      call_signature << block if block

      Module.new do
        method_name = proc.inspect
        define_method(method_name, proc)
        binding.local_variable_set(:"#{prefix}_unbound", instance_method(method_name))
      end

      lambda = proc.lambda? if lambda.nil?

      binding.eval <<~RUBY
        #{lambda ? "lambda" : "proc "} do #{"|#{signature.join(", ")}|" unless signature.empty?}
          #{extra_lines.join("\n  ")}
          #{prefix}_unbound.bind_call(self, #{call_signature.join(", ")})
        end
      RUBY
    end
  end
end
