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
          loader.inflector.inflect("ehr" => "EHR", "fhir" => "FHIR", "smart" => "SMART")
        end
      end

      # Register EHR, FHIR, and SMART as ActiveSupport acronyms too.
      # Rails routing uses its own inflector (not Zeitwerk's) to
      # constantize controller paths — without this, routes pointing
      # at "lakeraven/ehr/patients#show" would try to resolve
      # Lakeraven::Ehr::PatientsController and fail.
      initializer "lakeraven_ehr.acronyms", before: :set_autoload_paths do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "EHR"
          inflect.acronym "FHIR"
          inflect.acronym "SMART"
        end
      end
    end
  end
end
