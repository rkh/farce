# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "resolv"

module Farce
  # Small module wrapping Ruby's resolver in a way that permits it to be used outside of the main ractor.
  # Just replace calls to `Resolv` with `Farce::Resolv`.
  module Resolv
    autoload :DNS, "farce/resolv/dns"

    Hosts      = ::Resolv::Hosts
    VERSION    = ::Resolv::VERSION
    IDENTIFIER = Internal::Counter.new
    DEFAULT_CONFIG =
      if RUBY_PLATFORM.match?(/mswin|mingw/)
        Ractor.make_shareable(::Resolv::DNS::Config.default_config_hash, copy: true)
      end

    # Patch only message IDs and request-ID storage, including standard Resolv callers.
    module MessageExtension
      def initialize(id = IDENTIFIER.add(1) & 0xffff) = super
    end

    # Upstream requesters name ::Resolv::DNS directly, so forward their ID calls.
    module RequestIDExtension
      def allocate_request_id(...) = DNS.allocate_request_id(...)
      def free_request_id(...)     = DNS.free_request_id(...)
    end

    ::Resolv::DNS::Message.prepend(MessageExtension)
    ::Resolv::DNS.singleton_class.prepend(RequestIDExtension)
    private_constant :DEFAULT_CONFIG, :IDENTIFIER, :MessageExtension, :RequestIDExtension

    # @return [::Resolv] the resolver instance for the current ractor
    def self.resolver = Internal::Storage.store_if_absent(self) { new }

    # @return [::Resolv] a new resolver instance
    def self.new(resolvers = nil, **config)
      if resolvers.nil? || resolvers.is_a?(Hash)
        defaults = DEFAULT_CONFIG || DNS::Config.default_config_hash
        config = defaults.merge(resolvers || config)
        resolvers = [Hosts.new, DNS.new(config)]
      end
      ::Resolv.new(resolvers)
    end

    # @!method getaddress(name)
    #   @!scope class
    #   Resolves a hostname to its corresponding IP address.
    #   @param name [String] the name to resolve
    #   @return [String] the resolved address
    # @!method getaddresses(name)
    #   @!scope class
    #   Resolves a hostname to its corresponding IP addresses.
    #   @param name [String] the name to resolve
    #   @return [Array<String>] the resolved addresses
    # @!method each_address(name)
    #   @!scope class
    #   Resolves a hostname to its corresponding IP addresses one by one.
    #   @param name [String] the name to resolve
    #   @yield [address] each name corresponding to the given address
    #   @yieldparam address [String] the resolved address
    # @!method getname(address)
    #   @!scope class
    #   Resolves an IP address to its corresponding host name.
    #   @param address [String] the address to resolve
    #   @return [String] the resolved name
    # @!method getnames(address)
    #   @!scope class
    #   Resolves an IP address to its corresponding host names.
    #   @param address [String] the address to resolve
    #   @return [Array<String>] the resolved names
    # @!method each_name(address)
    #   @!scope class
    #   Resolves an IP address to its corresponding host names one by one.
    #   @param address [String] the address to resolve
    #   @yield [name] each name corresponding to the given address
    #   @yieldparam name [String] the resolved name
    Internal.delegate(singleton_class, :resolver, :getaddress, :getaddresses, :each_address, :getname, :getnames,
      :each_name)
  end
end
