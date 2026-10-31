# frozen_string_literal: true

module Lakeraven
  module EHR
    module Gpra
      # One measure's care-gap patient list from the latest GPRA run (#780):
      # who is in the denominator and still needs care, with rook's reason.
      # Names are read from RPMS when the list is opened; the run holds DFNs.
      class CareGapsController < WebController
        PER_PAGE = 50

        before_action :require_authentication
        before_action -> { require_capability!("gpra.patient_lists") }

        # GET /gpra/measures/:measure_id/care_gaps?page=
        def index
          @run = GpraRun.latest_succeeded
          @measure = @run&.measure(params[:measure_id])
          return render plain: "No such measure in the latest GPRA report", status: :not_found if @measure.nil?

          gaps = @run.care_gaps.where(measure_id: @measure["id"]).order(:id)
          @total = gaps.count
          @page = [ params[:page].to_i, 1 ].max
          @pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max
          @gaps = gaps.offset((@page - 1) * PER_PAGE).limit(PER_PAGE).map do |gap|
            { dfn: gap.patient_dfn, reason: gap.reason, header: PatientGateway.brief_header(gap.patient_dfn) }
          end
        end
      end
    end
  end
end
