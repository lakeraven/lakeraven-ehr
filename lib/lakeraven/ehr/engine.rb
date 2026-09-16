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

      initializer "lakeraven-ehr.inflections" do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "EHR"
          inflect.acronym "FHIR"
        end
      end
    end
  end
end
