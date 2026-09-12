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
    # AUTHORIZATION — decided, one story with the FHIR surface (#486)
    # ---------------------------------------------------------------
    # This surface runs on the SAME credential as the chart: a SMART token,
    # with its scopes, expiry, revocation, patient compartment and DUZ. It
    # briefly had a scheme of its own — `session[:user_type]` — which meant
    # none of the token's controls reached it, and a keyless provider holding
    # an empty-scope token could read self-harm answers. There is no second
    # scheme now: no token, no screening.
    #
    # A browser gets that token from the sign-on bridge in #486; until that
    # merges this surface is reachable only with a token, exactly like
    # ChartsController. The session still carries the patient CONTEXT (which
    # record the clinician deliberately opened) — that is a different question
    # from what the credential may do, and both are asked.
    #
    # This controller is only the CLINICIAN surface. All scoring and
    # persistence live in ScreeningEntryService, which reads no session — the
    # tokenized pre-visit link (#471) will call the same service.
    class ScreeningsController < WebController
      include BrowserSmartAuthentication
      # Fails closed: an access that cannot be recorded is not completed, and
      # a refusal is recorded too.
      include FailClosedClinicalAudit
      include ClinicianPatientContext

      # The item-level answers are what this surface reads and writes, and they
      # are the sensitive half of the feature (the score alone is an
      # Observation). Scope is asked for by that name.
      SCREENING_RESOURCE = "QuestionnaireResponse"

      before_action :authenticate_smart_token!
      before_action :authorize_screening_scope!
      before_action :load_patient
      # Two separate questions, both asked: may this CREDENTIAL leave its
      # patient compartment (token), and has this SESSION deliberately opened
      # this patient's record (deliberate access + audit).
      before_action :enforce_token_patient_context!
      before_action :enforce_patient_context!
      before_action :load_instrument, only: %i[new create]

      # Trend view: every scored screening for this patient, oldest first.
      # The charting work (#483) reads the same records.
      def index
        @responses = displayable(ScreeningResponse.for_patient(@dfn))
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
          administered_by: screening_duz,
          source: ScreeningResponse::SOURCE_CLINICIAN,
          # Raw, uncoerced: the service decides what an acknowledgement is. A
          # controller-side `.present?` would make the clinical-safety gate
          # depend on caller coercion, and every other caller (the pre-visit
          # link, #471) would need its own.
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
        return render_undisplayable unless @response.publishable?

        @instrument = @response.instrument
      end

      private

      # -- Authorization --------------------------------------------------------

      # Verb-aware: a read scope must never authorize a write. (#486 generalizes
      # this as SmartAuthentication#can_perform?; this call site adopts it on
      # merge — there must not be two versions of the rule for long.)
      def authorize_screening_scope!
        permitted = request.get? ? can_read?(SCREENING_RESOURCE) : can_write?(SCREENING_RESOURCE)
        return true if permitted

        verb = request.get? ? "read" : "record"
        render_forbidden("Insufficient scope to #{verb} #{SCREENING_RESOURCE}")
        false
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      # The DUZ follows the TOKEN, never the ambient session: the identity a
      # write is signed under has to come from the same credential the
      # authorization was decided by, or the record disagrees with the
      # authorization. (#486 generalizes this as
      # SmartAuthentication#current_duz, which additionally requires the token
      # to be a browser-session one; this call site adopts it on merge.)
      def screening_duz = current_token&.resource_owner_id.to_s.presence

      # -- Audit (FailClosedClinicalAudit hooks) --------------------------------

      # Recording a screening is a write; everything else on this surface reads.
      def audit_action = action_name == "create" ? "C" : "R"

      def fhir_resource_type = SCREENING_RESOURCE

      # Opening a patient record is state; a screening read is not. Nothing to
      # undo here — see PatientContextsController.
      def audit_agent_attributes
        duz = screening_duz
        return super if duz.blank?

        { agent_who_type: "Practitioner", agent_who_identifier: duz }
      end

      # -- Loading --------------------------------------------------------------

      def load_patient
        @dfn = params[:dfn]
      end

      def load_instrument
        @instrument = ScreeningInstrument.find(params[:instrument])
        return if @instrument

        render plain: "Unknown screening instrument", status: :not_found
      end

      # Rows that cannot be displayed safely — an instrument that no longer
      # exists, a row that contradicts its own answers — are left out of the
      # history rather than raising on the way to rendering it.
      def displayable(responses)
        responses.select do |response|
          next true if response.publishable?

          Rails.logger.warn("[screening] #{response.id} withheld from history: not publishable")
          false
        end
      end

      # Fail closed and say why: this record exists, and it cannot be shown,
      # which is a different statement from "no such screening".
      def render_undisplayable
        render plain: "This screening cannot be displayed: the stored record does not " \
                      "agree with itself. It has been left unchanged; report the id to support.",
               status: :unprocessable_entity
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
