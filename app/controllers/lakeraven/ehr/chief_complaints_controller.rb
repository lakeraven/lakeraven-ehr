# frozen_string_literal: true

module Lakeraven
  module EHR
    # The medical assistant records why the patient came, on one of the
    # patient's open visits (rpms-ux S-TRI-07.1). RPMS files it, through the
    # BGOCC SET VueCentric's Triage tab uses, as the connection's signed-on
    # user; the app keeps nothing. The visit is read again when the form is
    # posted: only a visit open now, and this patient's, is charted on.
    class ChiefComplaintsController < WebController
      include VisitCharting

      def new
        @open_visits = read_open_visits(@dfn)
      end

      def create
        @text = params[:chief_complaint].is_a?(String) ? params[:chief_complaint].strip : ""
        @visit_ien = params[:visit_ien].is_a?(String) ? params[:visit_ien] : nil
        @open_visits = read_open_visits(@dfn)
        return refuse("Choose one of the patient's open visits.") unless chosen_open_visit(@dfn, @visit_ien)
        return refuse("Enter the chief complaint as one line of up to 240 characters, without a caret (^).") unless ChiefComplaintGateway.valid_text?(@text)

        file_chief_complaint
      end

      private

      def charted_thing = "chief complaint"

      def file_chief_complaint
        result = ChiefComplaintGateway.record(canonical_ien(@visit_ien), @text)
        if result.is_a?(Hash) && result[:success]
          @write_outcome = :written
          redirect_to patient_chart_path(@dfn), notice: "Chief complaint recorded on the visit."
        else
          @write_outcome = :nothing_written
          refuse("RPMS did not record the chief complaint. Nothing was saved.")
        end
      rescue *UNKNOWN_OUTCOME_ERRORS => error
        Rails.logger.error("[chief_complaint] record raised #{error.class}")
        @write_outcome = :unknown
        refuse("The outcome is unknown. Check the visit before entering the chief complaint again.")
      end
    end
  end
end
