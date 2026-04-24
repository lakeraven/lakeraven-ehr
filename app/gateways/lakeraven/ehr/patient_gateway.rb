# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientGateway
      class << self
        def find(dfn)
          if fhir_mode?
            FHIRReadGateway.read("Patient", dfn)
          else
            find_via_rpc(dfn)
          end
        end

        def search(name_pattern)
          if fhir_mode?
            FHIRReadGateway.search("Patient", name: name_pattern)
          else
            search_via_rpc(name_pattern)
          end
        end

        def find_by_ssn(ssn)
          if fhir_mode?
            FHIRReadGateway.search("Patient", identifier: ssn).first
          else
            find_by_ssn_via_rpc(ssn)
          end
        end

        private

        def fhir_mode?
          RpmsRpc.configuration.fhir_client.present?
        end

        def find_via_rpc(dfn)
          require "rpms_rpc/mappings"
          attrs = RpmsRpc::DataMapper.patient_select.fetch_one(dfn.to_s, extras: { dfn: dfn.to_i })
          return nil unless attrs

          extended = RpmsRpc::DataMapper.patient_id_info.fetch_one(dfn.to_s)
          attrs.merge!(extended) if extended

          Patient.new(**attrs)
        end

        def search_via_rpc(name_pattern)
          require "rpms_rpc/mappings"
          results = RpmsRpc::DataMapper.patient_list.fetch_many(name_pattern, "1")
          results.map { |attrs| Patient.new(**attrs) }
        end

        def find_by_ssn_via_rpc(ssn)
          require "rpms_rpc/mappings"
          attrs = RpmsRpc::DataMapper.patient_ssn.fetch_one(ssn)
          attrs ? Patient.new(**attrs) : nil
        end
      end
    end
  end
end
