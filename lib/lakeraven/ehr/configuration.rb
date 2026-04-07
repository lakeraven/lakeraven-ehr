# frozen_string_literal: true

module Lakeraven
  module EHR
    # Application-level configuration for the engine.
    #
    # Host applications configure the engine via:
    #
    #   Lakeraven::EHR.configure do |config|
    #     config.adapter = MyAdapter.new
    #   end
    #
    # The adapter is the only required setting at boot.
    class Configuration
      attr_accessor :adapter

      def initialize
        @adapter = nil
      end
    end

    # Raised when engine code touches the adapter before the host has
    # configured one. Surfaces immediately, before any feature runs.
    class NotConfiguredError < StandardError; end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def reset_configuration!
        @configuration = Configuration.new
      end

      # Convenience accessor — engine code reads through here rather
      # than touching configuration directly.
      def adapter
        configuration.adapter || raise(
          NotConfiguredError,
          "Lakeraven::EHR.adapter is not configured. " \
          "Set one via Lakeraven::EHR.configure { |c| c.adapter = ... } " \
          "before using the engine."
        )
      end
    end
  end
end
