# frozen_string_literal: true

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR

      initializer "lakeraven-ehr.doorkeeper_extensions" do |app|
        app.config.to_prepare do
          # Backend-services client bindings live on Doorkeeper::Application;
          # registration-time JWKS transport rules ride along.
          unless Doorkeeper::Application.include?(Lakeraven::EHR::BackendClientRegistration)
            Doorkeeper::Application.include(Lakeraven::EHR::BackendClientRegistration)
          end
        end
      end

      # The VistA ACCESS CODE is a credential, and the sign-on form submits it
      # as `username` — a name no default filter matches, so it was written to
      # the log in cleartext on every sign-on attempt and rode along in every
      # exception report. Filter the field names this engine actually uses for
      # credentials, in the HOST app's config, since that is where request
      # logging reads them from.
      initializer "lakeraven-ehr.filter_credentials" do |app|
        app.config.filter_parameters += %i[username access_code verify_code]
      end

      # The live broker client, built once per process from the environment
      # (#539). Before this nothing built one, so every live request raised
      # NotConfiguredError. It runs after the host app's initializers so a
      # client configured there (or the SPIKE_MOCK_RPC demo mock) wins.
      config.after_initialize do
        Lakeraven::EHR::Engine.configure_rpms_broker!
      end

      # VISTA_BROKER picks the wire (cia for an RPMS CIA broker: a YDB stack's
      # 9100, an IRIS stack's 9200; xwb for stock VistA), VISTA_RPC_HOST and
      # VISTA_RPC_PORT say where. No host, no client. The socket opens at
      # sign-on, not here, so the app boots with the broker down.
      def self.configure_rpms_broker!(env = ENV)
        return if env["VISTA_RPC_HOST"].to_s.empty?

        require "rpms_rpc/core"
        require "rpms_rpc/broker_factory"
        return if RpmsRpc.configuration.client

        client = RpmsRpc.client_for(env["VISTA_BROKER"], host: env["VISTA_RPC_HOST"], port: env["VISTA_RPC_PORT"])
        RpmsRpc.configure { |c| c.client = client }
      end

      initializer "lakeraven-ehr.inflections" do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "EHR"
          inflect.acronym "FHIR"
        end
      end
    end
  end
end
