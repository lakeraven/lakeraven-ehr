# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientGateway
      class << self
        def find(dfn)
          attrs = backend.patient_api.find(dfn.to_i)
          return nil unless attrs

          build_patient(attrs)
        end

        def search(name_pattern)
          results = backend.patient_api.search(name_pattern)
          results.map { |attrs| build_patient(attrs) }
        end

        def find_by_ssn(ssn)
          attrs = backend.patient_api.find_by_ssn(ssn)
          attrs ? build_patient(attrs) : nil
        end

        # Chart-banner projection — returns the issue-#60 contract hash or nil.
        # Delegates to the backend's patient API. Coerces dfn to_i to match
        # the convention used by `find` and `find_by_ssn` on this gateway.
        def brief_header(dfn)
          backend.patient_api.brief_header(dfn.to_i)
        end

        private

        def backend
          Backend.current
        end

        # rpms-rpc returns fields beyond the Patient model's declared
        # attributes (race_code, site_ien, etc.); slice to model.attribute_names
        # so ActiveModel doesn't raise UnknownAttributeError on the extras.
        def build_patient(attrs)
          known = Patient.attribute_names.map(&:to_sym)
          Patient.new(**attrs.slice(*known))
        end
      end
    end
  end
end
