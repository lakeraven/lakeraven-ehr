# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class PatientGateway
      class << self
        def find(dfn)
          attrs = RpmsRpc::DataMapper.patient_select.fetch_one(dfn.to_s, extras: { dfn: dfn.to_i })
          return nil unless attrs

          extended = RpmsRpc::DataMapper.patient_id_info.fetch_one(dfn.to_s)
          attrs.merge!(extended) if extended

          Patient.new(**attrs)
        end

        def search(name_pattern)
          results = RpmsRpc::DataMapper.patient_list.fetch_many(name_pattern, "1")
          results.map { |attrs| Patient.new(**attrs) }
        end

        def find_by_ssn(ssn)
          attrs = RpmsRpc::DataMapper.patient_ssn.fetch_one(ssn)
          attrs ? Patient.new(**attrs) : nil
        end
      end
    end
  end
end
