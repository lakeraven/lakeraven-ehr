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

        # The business-identifier MRN a consumer searches by is, in IHS
        # RPMS, the health record number (HRN) — a real wire field, not an
        # engine-side invention. Resolution is entirely rpms-rpc's concern
        # (RpmsRpc::Patient.find_by_hrn, backed by AGG LOOKUP PATIENTS'
        # TYPE="H" cross-reference lookup); this gateway never sees an RPC
        # name or a wire position.
        def find_by_mrn(mrn)
          return nil if mrn.blank?

          attrs = RpmsRpc::Patient.find_by_hrn(mrn)
          return nil unless attrs

          build_patient(attrs)
        end

        # Chart-banner projection — returns the issue-#60 contract hash or nil.
        # Delegates to RpmsRpc::Patient.brief_header (lakeraven/rpms-rpc#60).
        # Coerces dfn to_i to match the convention used by `find` and
        # `find_by_ssn` on this gateway.
        def brief_header(dfn)
          RpmsRpc::Patient.brief_header(dfn.to_i)
        end

        private

        # rpms-rpc returns fields beyond the Patient model's declared
        # attributes (race_code, site_ien, etc.); slice to model.attribute_names
        # so ActiveModel doesn't raise UnknownAttributeError on the extras.
        def build_patient(attrs)
          attrs = attrs.dup
          attrs[:mrn] = attrs.delete(:hrn) if attrs.key?(:hrn)

          known = Patient.attribute_names.map(&:to_sym)
          Patient.new(**attrs.slice(*known))
        end
      end
    end
  end
end
