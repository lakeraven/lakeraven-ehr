# frozen_string_literal: true

module Lakeraven
  module EHR
    class MeasuresController < ApplicationController
      def index
        measures = Measure.all
        render_bundle(measures.map(&:to_fhir))
      end
    end
  end
end
