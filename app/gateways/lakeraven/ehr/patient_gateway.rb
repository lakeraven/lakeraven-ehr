# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    class PatientGateway
      class << self
        def find(dfn)
          attrs = RpmsRpc::Patient.find(dfn.to_i)
          return nil unless attrs

          build_patient(attrs)
        end

        def search(name_pattern)
          results = RpmsRpc::Patient.search(name_pattern)
          results.map { |attrs| build_patient(attrs) }
        end

        def find_by_ssn(ssn)
          attrs = RpmsRpc::Patient.find_by_ssn(ssn)
          attrs ? build_patient(attrs) : nil
        end

        # Chart-banner projection — returns the issue-#60 contract hash or nil.
        # Delegates to RpmsRpc::Patient.brief_header (lakeraven/rpms-rpc#60).
        # Coerces dfn to_i to match the convention used by `find` and
        # `find_by_ssn` on this gateway.
        def brief_header(dfn)
          RpmsRpc::Patient.brief_header(dfn.to_i)
        end

        # Telecom projection — VistA PATIENT #2 fields .131/.132/.133/.134 read
        # via DDR GETS ENTRY DATA. Returns the rpms-rpc contract hash
        # { dfn:, phone_home:, phone_work:, phone_cell:, email: } or nil when
        # the read failed, which the caller must keep distinct from "no phone
        # on file".
        def contact(dfn)
          RpmsRpc::Patient.contact(dfn.to_i)
        end

        private

        # rpms-rpc returns fields beyond the Patient model's declared
        # attributes (race_code, site_ien, etc.); slice to model.attribute_names
        # so ActiveModel doesn't raise UnknownAttributeError on the extras.
        def build_patient(attrs)
          known = Patient.attribute_names.map(&:to_sym)
          Patient.new(**attrs.slice(*known))
        end
      end
    end
  end
end
