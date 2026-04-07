# frozen_string_literal: true

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR

      # Tell Zeitwerk that "ehr" should resolve to the EHR constant
      # (capitalized acronym) rather than the default "Ehr". "fhir"
      # gets the same treatment so app/.../fhir/patient_serializer.rb
      # resolves to Lakeraven::EHR::FHIR::PatientSerializer.
      config.before_initialize do
        Rails.autoloaders.each do |loader|
          loader.inflector.inflect("ehr" => "EHR", "fhir" => "FHIR")
        end
      end
    end
  end
end
