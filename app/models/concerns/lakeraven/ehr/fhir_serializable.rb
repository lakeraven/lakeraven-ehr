# frozen_string_literal: true

module Lakeraven
  module EHR
    # Fail-safe builders for FHIR Identifier, Reference, CodeableConcept, and Period.
    # Absent input stays absent: these methods never invent a value.
    module FHIRSerializable
      extend ActiveSupport::Concern

      private

      def build_identifier(system:, value:)
        return nil if system.nil? || value.nil?

        { system: system, value: value.to_s }
      end

      def build_reference(resource_type, id)
        return nil if id.nil?

        { reference: "#{resource_type}/#{id}" }
      end

      def build_codeable_concept(system:, code:, display:)
        return nil if code.nil?

        coding = { system: system, code: code, display: display }.compact
        { coding: [ coding ], text: display }.compact
      end

      def build_period(start_date:, end_date: nil)
        {
          start: serialize_period_bound(start_date),
          end: serialize_period_bound(end_date)
        }.compact.presence
      end

      # A string is kept as given; a blank string is absent. Date, Time,
      # DateTime, and TimeWithZone use iso8601.
      def serialize_period_bound(value)
        return value.presence if value.is_a?(String)

        value.iso8601 if value.respond_to?(:iso8601)
      end
    end
  end
end
