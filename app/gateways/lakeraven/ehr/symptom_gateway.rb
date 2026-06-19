# frozen_string_literal: true

require "rpms_rpc/api/symptom"

module Lakeraven
  module EHR
    # Allergy-symptom catalog lookup, driving the order-entry
    # allergy-precheck UI.
    # Wraps RpmsRpc::Symptom 
    class SymptomGateway
      def self.search(query, via: default_provider)
        return [] if via.nil?

        via.search(query.to_s)
      end

      def self.defaults(via: default_provider)
        return [] if via.nil?

        via.defaults
      end

      def self.default_provider
        ::RpmsRpc::Symptom
      end
    end
  end
end
