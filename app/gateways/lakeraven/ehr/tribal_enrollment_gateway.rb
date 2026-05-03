# frozen_string_literal: true

require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    class TribalEnrollmentGateway
      def self.enrollment_details(dfn)
        RpmsRpc::Tribal.enrollment(dfn)
      end

      def self.validate(enrollment_number)
        RpmsRpc::Tribal.validate(enrollment_number)
      end

      def self.eligibility(dfn)
        RpmsRpc::Tribal.eligibility(dfn)
      end

      def self.service_unit(dfn)
        RpmsRpc::Tribal.service_unit(dfn)
      end

      def self.tribe_info(code)
        RpmsRpc::Tribal.tribe_info(code)
      end
    end
  end
end
