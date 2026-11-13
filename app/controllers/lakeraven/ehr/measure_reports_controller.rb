# frozen_string_literal: true

module Lakeraven
  module EHR
    class MeasureReportsController < ApplicationController
      rate_limit only: :index
      disclosure_surface :fhir_api

      def index
        # Simplified: returns empty bundle. Full implementation needs patient data access.
        render_bundle_egress([])
      end
    end
  end
end
