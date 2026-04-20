# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIRSerializable
      extend ActiveSupport::Concern

      class_methods do
        def from_fhir(fhir_resource)
          fhir_resource = FHIR.from_contents(fhir_resource) if fhir_resource.is_a?(Hash)
          return nil unless fhir_resource.is_a?(resource_class)

          find_or_initialize_by(id: fhir_resource.id).tap do |record|
            record.assign_attributes(from_fhir_attributes(fhir_resource))
          end
        end

        def from_fhir_attributes(fhir_resource)
          raise NotImplementedError
        end

        def resource_class
          raise NotImplementedError
        end
      end

      def as_json(*)
        fhir_resource = to_fhir
        openstruct_to_hash(fhir_resource)
      end

      private

      def openstruct_to_hash(obj)
        case obj
        when OpenStruct
          obj.to_h.transform_values { |v| openstruct_to_hash(v) }
        when Array
          obj.map { |v| openstruct_to_hash(v) }
        when Hash
          obj.transform_values { |v| openstruct_to_hash(v) }
        else
          obj
        end
      end
    end
  end
end
