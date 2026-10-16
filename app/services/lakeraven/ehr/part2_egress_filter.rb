# frozen_string_literal: true

module Lakeraven
  module EHR
    # Egress seam for a disclosing response.
    #
    # Callers pass the payload they are about to send: C-CDA sections
    # (TransitionsOfCareController), a FHIR resource or Bundle hash, or
    # an NDJSON export file (String). TransitionsOfCareController
    # serializes sections and does not build a document when the return
    # value is not a sections hash. FHIR and NDJSON callers render the
    # return value, and refuse when it is nil or not usable for that
    # response.
    #
    # What this method does: return its input unchanged. It does not
    # classify records and it does not remove any.
    class Part2EgressFilter
      def self.call(payload)
        payload
      end
    end
  end
end
