# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class PatientGateway < BaseGateway
      class << self
        # Find a patient by DFN.
        # Calls ORWPT SELECT + ORWPT ID INFO, merges into one hash,
        # returns a Patient model instance.
        def find(dfn)
          response = rpc_client.call_rpc("ORWPT SELECT", dfn.to_s)
          return nil if empty_response?(response)

          attrs = RpmsRpc::DataMapper[:patient_select].parse_one(response, extras: { dfn: dfn.to_i })
          return nil unless attrs

          id_response = rpc_client.call_rpc("ORWPT ID INFO", dfn.to_s)
          unless empty_response?(id_response)
            extended = RpmsRpc::DataMapper[:patient_id_info].parse_one(id_response)
            attrs.merge!(extended) if extended
          end

          Patient.new(**attrs)
        end

        # Search patients by name. Returns array of Patient stubs (dfn + name only).
        def search(name_pattern)
          response = rpc_client.call_rpc("ORWPT LIST ALL", name_pattern, "1")
          return [] if empty_response?(response)

          RpmsRpc::DataMapper[:patient_list].parse_many(response).map do |attrs|
            Patient.new(**attrs)
          end
        end

        # Find patient by SSN.
        def find_by_ssn(ssn)
          response = rpc_client.call_rpc("ORWPT FULLSSN", ssn)
          return nil if empty_response?(response)

          attrs = RpmsRpc::DataMapper[:patient_ssn].parse_one(response)
          attrs ? Patient.new(**attrs) : nil
        end
      end
    end
  end
end
