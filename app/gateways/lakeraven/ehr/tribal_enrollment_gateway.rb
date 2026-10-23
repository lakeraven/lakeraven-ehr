# frozen_string_literal: true

require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    class TribalEnrollmentGateway
      def self.enrollment_details(dfn)
        CapabilityGuard.ensure!(:tribal_enrollment)
        RpmsRpc::Tribal.enrollment(dfn)
      end

      def self.validate(enrollment_number)
        CapabilityGuard.ensure!(:tribal_enrollment)
        RpmsRpc::Tribal.validate(enrollment_number)
      end

      def self.eligibility(dfn)
        CapabilityGuard.ensure!(:tribal_enrollment)
        RpmsRpc::Tribal.eligibility(dfn)
      end

      # 0.3.0 signatures: these are TABLE lookups by IEN over #9999999.22 /
      # #9999999.03, not per-patient or by-code reads (the placeholder's dfn /
      # tribe-code arguments were fabricated).
      def self.service_unit(ien)
        CapabilityGuard.ensure!(:tribal_enrollment)
        RpmsRpc::Tribal.service_unit(ien)
      end

      def self.tribe_info(ien)
        CapabilityGuard.ensure!(:tribal_enrollment)
        RpmsRpc::Tribal.tribe_info(ien)
      end
    end
  end
end
