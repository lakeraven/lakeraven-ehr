# frozen_string_literal: true

module Lakeraven
  module EHR
    # A clinician finds a diagnosis by its clinical term, the search VueCentric's
    # problem entry runs before a new diagnosis is added (rpms-ux S-VIS-02.2,
    # its search step). RPMS answers from its terminology package, BSTS: the
    # SNOMED CT concepts whose terms match, each with its ICD-10-CM codes, the
    # words that start with what was typed, and one concept's detail.
    #
    # Terminology is not patient data, so the page needs a sign-on and no
    # patient context. A refusal or a failed read renders RPMS's own reason
    # (RpmsUnavailableRendering); no match says BSTS holds none.
    class DiagnosisSearchesController < WebController
      rate_limit only: %i[show concept]

      include RpmsUnavailableRendering

      before_action :require_authentication

      def show
        @query = params[:q].is_a?(String) ? params[:q].strip : ""
        return if @query.empty?

        unless TerminologyGateway.searchable?(@query)
          @refusal = "Enter a term of up to 80 characters, without | or ^."
          return render :show, status: :unprocessable_entity
        end

        @concepts = TerminologyGateway.search(@query)
        @words = TerminologyGateway.words_starting(@query)
      end

      # With a patient's record open, the concept page offers to add the
      # concept to that patient's problem list (ProblemsController).
      def concept
        @concept = TerminologyGateway.concept(params[:dts_id])
        return render :concept_missing, status: :not_found if @concept.nil?

        @open_dfn = session[ClinicianPatientContext::SESSION_KEY].presence
      end
    end
  end
end
