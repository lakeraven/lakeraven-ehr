# frozen_string_literal: true

module Lakeraven
  module EHR
    # Server-rendered PHQ-9 / GAD-7 administration (issue #474).
    #
    # Progressive enhancement, no JavaScript: the whole flow — including the
    # item-9 safety gate — is plain form posts and server re-renders, so it
    # behaves identically on a locked-down clinic tablet with scripting off.
    # An unsuccessful POST re-renders `new` with the submitted answers still
    # selected, the missing items called out, and/or the safety prompt shown;
    # nothing is stored until the submission is complete and (where required)
    # acknowledged.
    #
    # This controller is only the CLINICIAN surface. All scoring and
    # persistence live in ScreeningEntryService, which reads no session — the
    # tokenized pre-visit link (#471) will call the same service.
    class ScreeningsController < WebController
      # Every FHIR controller and ChartsController audit clinical access; this
      # is the engine's first session-authenticated PHI-reading web surface, and
      # the one that renders self-harm disclosures, so it follows the same
      # policy rather than being the exception to it.
      include AuditableClinicalAccess

      before_action :require_authentication
      before_action :load_patient
      before_action :load_instrument, only: %i[new create]

      # Trend view: every scored screening for this patient, oldest first.
      # The charting work (#483) reads the same records.
      def index
        @responses = ScreeningResponse.for_patient(@dfn)
      end

      # TODO(#480): `encounter_ien` arrives as a query param and is rendered as
      # a free-text field because there is no encounter picker in the web UI
      # yet. The scheduling surface (#480, Sprint 3) supplies it; until then
      # this is interim, not a finished design. See the note in new.html.erb.
      def new
        @answers = {}
        @encounter_ien = params[:encounter_ien]
      end

      def create
        @answers = submitted_answers
        @encounter_ien = params[:encounter_ien]

        @result = ScreeningEntryService.new(
          instrument: @instrument,
          patient_dfn: @dfn,
          encounter_ien: @encounter_ien,
          answers: @answers,
          administered_by: session[:duz],
          source: ScreeningResponse::SOURCE_CLINICIAN,
          # Raw, uncoerced: the service casts it. A controller-side `.present?`
          # would make the clinical-safety gate depend on caller coercion, and
          # every other caller (the pre-visit link, #471) would need its own.
          safety_acknowledged: params[:safety_acknowledged]
        ).save

        return render :new, status: :unprocessable_entity unless @result.success?

        redirect_to patient_screening_path(@dfn, @result.record.id),
                    notice: "#{@instrument.short_title} recorded — " \
                            "score #{@result.record.total_score}, #{@result.record.severity_band}."
      end

      def show
        @response = ScreeningResponse.for_patient(@dfn).find_by(id: params[:id])
        return render plain: "Screening not found", status: :not_found unless @response

        @instrument = @response.instrument
      end

      private

      # -- Audit (AuditableClinicalAccess hooks) --------------------------------
      #
      # This surface authenticates a CLINICIAN SESSION rather than a Doorkeeper
      # token, so the concern's token branch does not apply. The overrides stay
      # in the controller — the concern itself is shared with the FHIR
      # controllers and PR #486 is editing it.

      def current_token = nil

      # Fixed marker, per the concern's contract: it only answers "is this
      # request auditable at all?". The acting identity goes in the agent
      # attributes below.
      def unauthenticated_audit_actor = ("clinician-session" if session[:duz].present?)

      # The agent is the signed-in clinician (DUZ from the session established
      # at sign-on), not an OAuth application.
      def audit_agent_attributes
        { agent_who_type: "Practitioner", agent_who_identifier: session[:duz] }
      end

      # Recording a screening is a write; everything else on this surface reads.
      def audit_action = action_name == "create" ? "C" : "R"

      # The item-level answers are the sensitive half of this surface, and they
      # are what `show` renders.
      def fhir_resource_type = "QuestionnaireResponse"

      def load_patient
        @dfn = params[:dfn]
      end

      def load_instrument
        @instrument = ScreeningInstrument.find(params[:instrument])
        return if @instrument

        render plain: "Unknown screening instrument", status: :not_found
      end

      # Whitelisted BY DEFINITION: only link ids the instrument declares are
      # read, so no unexpected parameter can reach the service or the record.
      def submitted_answers
        raw = params[:answers]
        return {} unless raw.respond_to?(:to_unsafe_h)

        raw.to_unsafe_h.slice(*@instrument.link_ids)
      end
    end
  end
end
