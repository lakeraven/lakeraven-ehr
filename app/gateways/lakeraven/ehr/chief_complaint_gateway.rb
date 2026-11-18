# frozen_string_literal: true

require "rpms_rpc/api/chief_complaint"

module Lakeraven
  module EHR
    # The chief complaint on a visit, filed through RPMS's own BGOCC SET as
    # VueCentric's Triage tab files it (RpmsRpc::ChiefComplaint): V NARRATIVE
    # TEXT (#9000010.34), type CHIEF COMPLAINT, authored by the connection's
    # signed-on user. The app keeps no copy.
    class ChiefComplaintGateway
      def self.valid_text?(text) = ::RpmsRpc::ChiefComplaint.valid_text?(text)

      def self.record(visit_ien, text)
        CapabilityGuard.ensure!(:pcc_screens)
        ::RpmsRpc::ChiefComplaint.record(visit_ien, text)
      end
    end
  end
end
