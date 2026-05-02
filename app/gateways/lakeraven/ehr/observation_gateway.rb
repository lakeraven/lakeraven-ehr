# frozen_string_literal: true

require "rpms_rpc/api/vital"

module Lakeraven
  module EHR
    class ObservationGateway
      def self.for_patient(dfn)
        RpmsRpc::Vital.for_patient(dfn.to_s)
      end
    end
  end
end
