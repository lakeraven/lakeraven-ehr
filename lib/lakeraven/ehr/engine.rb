# frozen_string_literal: true

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR

      # The VistA ACCESS CODE is a credential, and the sign-on form submits it
      # as `username` — a name no default filter matches, so it was written to
      # the log in cleartext on every sign-on attempt and rode along in every
      # exception report. Filter the field names this engine actually uses for
      # credentials, in the HOST app's config, since that is where request
      # logging reads them from.
      initializer "lakeraven-ehr.filter_credentials" do |app|
        app.config.filter_parameters += %i[username access_code verify_code]
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
