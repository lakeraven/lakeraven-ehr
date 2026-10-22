# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # What every FHIR search on this server honours, in CapabilityStatement
      # shape.
      #
      # The constants are the ones FHIRSearchBundle enforces, so a declared
      # limit and an enforced limit cannot drift apart. There is no
      # CapabilityStatement to put this in yet (#574): when /metadata lands it
      # renders `rest_search_params` into `rest[].searchParam`, which is where
      # FHIR R4 puts parameters common to every resource.
      module SearchCapabilities
        DEFAULT_COUNT = 20
        MAX_COUNT = 100

        def self.rest_search_params
          [
            {
              name: "_count",
              type: "number",
              documentation: "Page size. Default #{DEFAULT_COUNT}, at most #{MAX_COUNT}. " \
                             "Any other value is refused with a 400 OperationOutcome."
            },
            {
              name: "_offset",
              type: "number",
              documentation: "Number of matches to skip before the page starts. Default 0. " \
                             "Bundle.link carries self, next and previous."
            }
          ]
        end
      end
    end
  end
end
