# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationGateway
      class << self
        def for_patient(dfn)
          backend.vital_api.for_patient(dfn.to_s)
        end

        def labs_for_patient(dfn, days: 90)
          backend.lab_api.for_patient(dfn.to_s, days: days)
        end

        private

        def backend
          Backend.current
        end
      end
    end
  end
end
