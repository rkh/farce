# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # @!visibility private
    module Autoloads
      def self.[](*, **)
        Module.new do
          define_singleton_method(:append_features) do |namespace|
            Autoloads.define(namespace, *, **)
          end
        end
      end

      SEGMENTS = { "io" => "IO" }.freeze
      private_constant :SEGMENTS

      def self.inflect(name, **inflections)
        inflections.fetch(name.to_sym) { name.split("_").map { SEGMENTS.fetch(it, it.capitalize) }.join }
      end

      def self.define(namespace, path = nil, skip: nil, **)
        path ||= namespace.name.gsub(/([a-z])([A-Z])/, "\\1_\\2").gsub("::", "/").downcase
        path = File.expand_path(path, "#{__dir__}/../..")
        skip = Set[*skip]

        skip.map!(&:to_s)

        Dir.glob("#{path}/*.rb").each do |file|
          base_name = File.basename(file, ".rb")
          next if base_name.start_with?("_") || base_name.start_with?(".") || skip.include?(base_name)
          const_name = inflect(base_name, **)
          next if namespace.const_defined?(const_name, false) || $LOADED_FEATURES.include?(file)
          namespace.autoload(const_name, file)
        end
      end

      def self.append_features(namespace) = define(namespace)
    end
  end
end
