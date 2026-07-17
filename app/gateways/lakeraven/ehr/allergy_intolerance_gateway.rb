# frozen_string_literal: true

require "rpms_rpc/api/allergy"

module Lakeraven
  module EHR
    class AllergyIntoleranceGateway
      def self.for_patient(dfn)
        Backend.current.allergy_api.for_patient(dfn.to_s)
      end
    end
  end
end
