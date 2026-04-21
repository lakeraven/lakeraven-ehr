# frozen_string_literal: true

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR

      initializer "lakeraven-ehr.inflections" do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "EHR"
          inflect.acronym "FHIR"
        end
      end
    end
  end
end
