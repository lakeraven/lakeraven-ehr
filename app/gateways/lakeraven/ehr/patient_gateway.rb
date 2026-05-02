# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    class PatientGateway
      class << self
        def find(dfn)
          attrs = RpmsRpc::Patient.find(dfn.to_i)
          return nil unless attrs

          Patient.new(**attrs)
        end

        def search(name_pattern)
          results = RpmsRpc::Patient.search(name_pattern)
          results.map { |attrs| Patient.new(**attrs) }
        end

        def find_by_ssn(ssn)
          attrs = RpmsRpc::Patient.find_by_ssn(ssn)
          attrs ? Patient.new(**attrs) : nil
        end
      end
    end
  end
end
