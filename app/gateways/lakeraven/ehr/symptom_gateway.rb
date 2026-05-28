# frozen_string_literal: true

begin
  require "rpms_rpc/api/symptom"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::Symptom.
end

module Lakeraven
  module EHR
    # Allergy-symptom catalog lookup, driving the order-entry
    # allergy-precheck UI.
    # Wraps RpmsRpc::Symptom (lakeraven/rpms-rpc#73).
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
        return nil unless defined?(::RpmsRpc::Symptom) &&
                          ::RpmsRpc::Symptom.respond_to?(:search)
        ::RpmsRpc::Symptom
      end
    end
  end
end
