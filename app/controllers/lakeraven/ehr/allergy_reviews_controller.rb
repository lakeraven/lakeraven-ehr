# frozen_string_literal: true

module Lakeraven
  module EHR
    # The medical assistant reviews the allergies with the patient and marks
    # them reviewed on one of the patient's open visits (rpms-ux S-TRI-04.1).
    # The banner shows the allergies on file; RPMS files the review through
    # the BGOVUPD SET VueCentric uses, as the connection's signed-on user. The
    # visit is read again when the form is posted.
    class AllergyReviewsController < WebController
      include VisitCharting

      def new
        @open_visits = read_open_visits(@dfn)
      end

      def create
        @visit_ien = params[:visit_ien].is_a?(String) ? params[:visit_ien] : nil
        @open_visits = read_open_visits(@dfn)
        return refuse("Choose one of the patient's open visits.") unless chosen_open_visit(@dfn, @visit_ien)

        file_review
      end

      private

      def charted_thing = "allergy review"

      def file_review
        result = ClinicalReviewGateway.allergies_reviewed(@dfn, canonical_ien(@visit_ien))
        if result.is_a?(Hash) && result[:success]
          @write_outcome = :written
          redirect_to patient_chart_path(@dfn), notice: "Allergies marked reviewed on the visit."
        else
          @write_outcome = :nothing_written
          refuse("RPMS did not record the review. Nothing was saved.")
        end
      rescue *UNKNOWN_OUTCOME_ERRORS => error
        Rails.logger.error("[allergy_review] record raised #{error.class}")
        @write_outcome = :unknown
        refuse("The outcome is unknown. Check the visit before marking the allergies reviewed again.")
      end
    end
  end
end
