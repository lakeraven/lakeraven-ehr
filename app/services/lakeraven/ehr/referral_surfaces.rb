# frozen_string_literal: true

module Lakeraven
  module EHR
    # The declared referral surfaces of the engine (#905, slice of #522).
    #
    # The December build is MH/BH only. Under 42 CFR 2.11 the clinic must not
    # hold itself out as offering SUD referral for treatment, so no referral
    # surface may offer or advertise a structured SUD path. Any new referral
    # surface must be declared here and shown (in referral_surfaces_test) to
    # offer no SUD path. Free text is never inspected or refused. The
    # dashboard is declared because it renders the pending-referral count.
    # Routes are named by full controller path, so a same-named controller in
    # another namespace is never mistaken for a declared surface.
    module ReferralSurfaces
      ROUTES = %w[
        lakeraven/ehr/dashboards#show lakeraven/ehr/pending_referrals#index
        lakeraven/ehr/service_requests#index lakeraven/ehr/service_requests#show
      ].freeze

      OFFERED_CODINGS = [ ServiceRequest::PATIENT_REFERRAL ].freeze

      # The only params origination accepts; any other key fails closed.
      ORIGINATION_FIELDS = %i[service_requested urgency reason_for_referral].freeze
    end
  end
end
