# frozen_string_literal: true

require "rpms_rpc/api/clinical_review"

module Lakeraven
  module EHR
    # That the patient's allergy list was reviewed on a visit, filed through
    # RPMS's own BGOVUPD SET as VueCentric files it (RpmsRpc::ClinicalReview):
    # V UPDATED/REVIEWED (#9000010.54), action ALLERGY LIST REVIEWED, by the
    # connection's signed-on user. The app keeps no copy.
    class ClinicalReviewGateway
      def self.allergies_reviewed(dfn, visit_ien)
        CapabilityGuard.ensure!(:pcc_screens)
        ::RpmsRpc::ClinicalReview.record(dfn, visit_ien, action: ::RpmsRpc::ClinicalReview::ALLERGY_LIST_REVIEWED)
      end
    end
  end
end
