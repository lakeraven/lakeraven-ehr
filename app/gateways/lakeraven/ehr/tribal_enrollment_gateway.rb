# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class TribalEnrollmentGateway
      def self.enrollment_details(dfn)
        RpmsRpc::DataMapper.tribal_enrollment.fetch_one(dfn.to_s)
      end

      def self.validate(enrollment_number)
        RpmsRpc::DataMapper.tribal_validation.fetch_one(enrollment_number.to_s)
      end

      def self.eligibility(dfn)
        RpmsRpc::DataMapper.enrollment_eligibility.fetch_one(dfn.to_s) ||
          { active: false, eligible_for_ihs: false }
      end

      def self.service_unit(dfn)
        RpmsRpc::DataMapper.service_unit.fetch_one(dfn.to_s)
      end

      def self.tribe_info(code)
        RpmsRpc::DataMapper.tribe_info.fetch_one(code.to_s)
      end
    end
  end
end
