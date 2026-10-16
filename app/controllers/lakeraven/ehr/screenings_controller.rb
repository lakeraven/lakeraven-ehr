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
    # A browser gets that token from the sign-on bridge (#486, on this base).
    # The session still carries the patient CONTEXT (which record the
    # clinician deliberately opened) — that is a different question from what
    # the credential may do, and both are asked.
    #
    # This controller is only the CLINICIAN surface. All scoring and
    # persistence live in ScreeningEntryService, which reads no session — the
    # tokenized pre-visit link (#471) will call the same service.
    class ScreeningsController < WebController
      include BrowserSmartAuthentication
      # Fail-closed audit — an access that cannot be recorded is not
      # completed, and a refusal is recorded too — comes from WebController's
      # AuditableClinicalAccess, which since #512 audits AROUND the action in
      # the action's own transaction. This controller only supplies the
      # audit hooks below.
      include ClinicianPatientContext
      include FHIRReadEgress

      FHIR_CONTENT_TYPE = "application/fhir+json"

      # The item-level answers are what this surface reads and writes, and they
      # are the sensitive half of the feature (the score alone is an
      # Observation). Scope is asked for by that name.
      SCREENING_RESOURCE = "QuestionnaireResponse"
      SCREENING_SCORE_EXT = "https://lakeraven.com/fhir/StructureDefinition/screening-total-score"
      SCREENING_BAND_EXT = "https://lakeraven.com/fhir/StructureDefinition/screening-severity-band"
      SCREENING_SAFETY_EXT = "https://lakeraven.com/fhir/StructureDefinition/screening-safety-flag"

      # What the HTML pages read back out of a filtered QuestionnaireResponse.
      ScreeningPage = Struct.new(
        :id, :effective_at, :instrument, :total_score, :severity_band,
        :encounter_ien, :answered_items, :safety_flagged,
        keyword_init: true
      ) do
        def safety_flagged? = !!safety_flagged
      end

      before_action :authenticate_smart_token!
      before_action :authorize_screening_scope!
      # Recording is a CLINICAL ACT, so it needs a clinician behind it.
      before_action :require_clinician_credential!, only: :create
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
        records = displayable(ScreeningResponse.for_patient(@dfn))
        filtered = filter_fhir_for_egress(screening_bundle(records))
        return refuse_unfiltered_fhir_egress unless filtered

        assign_egress_document(filtered)
        @responses = screening_pages(filtered)
      end

      # TODO(#480): `encounter_ien` arrives as a query param and is rendered as
      # a free-text field because there is no encounter picker in the web UI
      # yet. The scheduling surface (#480, Sprint 3) supplies it; until then
      # this is interim, not a finished design. See the note in new.html.erb.
      def new
        @answers = {}
        @encounter_ien = params[:encounter_ien]
        # Minted when the form is RENDERED: it identifies this submission, so a
        # double-tap or a back-button replay of the same form is one
        # administration, while a second screening later the same day comes
        # from a second form and is its own.
        @submission_token = SecureRandom.uuid
      end

      def create
        @answers = submitted_answers
        @encounter_ien = params[:encounter_ien]
        # Carried through a re-render (an incomplete form, the safety prompt) so
        # that acknowledging and resubmitting is still the SAME submission.
        @submission_token = params[:submission_token].presence

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
          safety_acknowledged: params[:safety_acknowledged],
          submission_token: @submission_token
        ).save

        return render :new, status: :unprocessable_entity unless @result.success?

        redirect_to patient_screening_path(@dfn, @result.record.id), notice: outcome_notice
      end

      def show
        record = ScreeningResponse.for_patient(@dfn).find_by(id: params[:id])
        return render plain: "Screening not found", status: :not_found unless record
        return render_undisplayable unless record.publishable?

        filtered = filter_fhir_for_egress(screening_bundle([ record ]))
        return refuse_unfiltered_fhir_egress unless filtered

        assign_egress_document(filtered)
        @response = screening_pages(filtered).first
        return render_egress_identity unless @response

        @instrument = @response.instrument
      end

      private

      # A replay wrote nothing. Saying "PHQ-9 recorded — score N" for a
      # submission that recorded nothing is how a discarded administration goes
      # unnoticed, so a collapse is reported as a collapse.
      def outcome_notice
        record = @result.record
        if @result.duplicate?
          "#{@instrument.short_title} was already recorded — " \
            "score #{record.total_score}, #{record.severity_band}. Nothing was recorded again."
        else
          "#{@instrument.short_title} recorded — " \
            "score #{record.total_score}, #{record.severity_band}."
        end
      end

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
      # authorization.
      #
      # It comes from `current_duz`, which is nil unless the token is a
      # clinician credential — reading `resource_owner_id` blind attributed
      # the administration, the acknowledgement trace and the audit log to the
      # PATIENT whenever the caller held a patient-scoped token, because that
      # field carries a patient dfn there.
      def screening_duz = current_duz

      # A screening is administered BY somebody. A credential with no clinician
      # behind it — a patient's own token, a backend/system token, anything not
      # minted by the sign-on bridge — cannot record one: the row would either
      # name nobody or name the wrong person, and the acknowledgement trace on
      # a self-harm disclosure is worth nothing if it can name the discloser.
      # Keyed on the DUZ itself, not on a second predicate that merely implies
      # it: `clinician_credential?` and `current_duz` could disagree, and a
      # token on an app NAMED like the sign-on app but carrying no
      # resource_owner_id (a client_credentials grant) passed the first and
      # then recorded a screening authored by nobody.
      def require_clinician_credential!
        return true if current_duz.present?

        render_forbidden("Recording a screening requires a clinician sign-on")
        false
      end

      # -- Audit (AuditableClinicalAccess hooks) --------------------------------
      # The verb map covers the action (create is a POST -> "C"), and
      # Practitioner attribution comes from the shared resolver via #486's
      # `browser_sso_token?`/`current_duz` — no per-controller overrides.

      # What this access actually touched, so that type and identifier agree:
      #
      #   * one screening (a read, or a create that produced one) is audited as
      #     QuestionnaireResponse/<its own id>. The patient is one unambiguous
      #     hop away, through the resource's own subject;
      #   * an action with no single resource of its own — the history, a
      #     refused create — is audited against Patient/<dfn>, the same pattern
      #     ChartsController uses for a patient-centric aggregate.
      #
      # Never QuestionnaireResponse/<dfn>, which resolves to some other
      # patient's screening. The reference rule itself (both halves derived
      # together, sanitized) lives in the shared concern since #512; this
      # surface only supplies the identifier a create cannot put in params.
      def fhir_resource_type = audited_screening_id ? SCREENING_RESOURCE : "Patient"

      def direct_audit_identifier = audited_screening_id || super

      # On a create the id exists only once the action has run — the audit row
      # is written after `yield`, inside the same transaction, so the new
      # record can name itself.
      def audited_screening_id
        return @result.record.id.to_s if @result&.record

        params[:id].presence
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

      # -- Egress ---------------------------------------------------------------
      # Index and show build a QuestionnaireResponse bundle, hand it to
      # Part2EgressFilter, and render only what comes back. A payload that
      # is not a screening bundle (the seam's marker) still has to show up
      # in the HTML; the pages put its id in a hidden element.

      def screening_bundle(records)
        {
          resourceType: "Bundle",
          type: "searchset",
          total: records.length,
          entry: records.map { |record| { resource: screening_resource(record) } }
        }
      end

      def screening_resource(record)
        record.to_questionnaire_response.merge(extension: screening_extensions(record))
      end

      def screening_extensions(record)
        [
          { url: SCREENING_SCORE_EXT, valueInteger: record.total_score },
          { url: SCREENING_BAND_EXT, valueString: record.severity_band },
          { url: SCREENING_SAFETY_EXT, valueBoolean: record.safety_flagged? }
        ]
      end

      def assign_egress_document(document)
        @egress_document = document
        # A normal screening bundle has no id. The seam's replacement
        # resource does, and the page has to show that id.
        @egress_label = fhir_value(document, "id").to_s
      end

      def render_egress_identity
        render html: helpers.tag.div(@egress_label, hidden: true), layout: true
      end

      def screening_pages(document)
        questionnaire_resources(document).filter_map { |resource| screening_page(resource) }
      end

      def screening_page(resource)
        fields = screening_page_fields(resource)
        ScreeningPage.new(**fields) if fields
      end

      def screening_page_fields(resource)
        instrument = instrument_for(resource)
        effective_at = egress_time(fhir_value(resource, "authored"))
        total = screening_total(resource, instrument)
        band = screening_band(resource, instrument, total)
        return if instrument.nil? || effective_at.nil? || total.nil? || band.blank?

        {
          id: fhir_value(resource, "id"),
          effective_at: effective_at,
          instrument: instrument,
          total_score: total,
          severity_band: band,
          encounter_ien: encounter_ien_from(resource),
          answered_items: answered_pairs(resource, instrument),
          safety_flagged: safety_flag_from(resource)
        }
      end

      def questionnaire_resources(document)
        resources = if fhir_value(document, "resourceType").to_s == "Bundle"
                      bundle_entry_resources(document)
                    else
                      [ document ]
                    end
        resources.select { |resource| questionnaire_response?(resource) }
      end

      def questionnaire_response?(resource)
        fhir_value(resource, "resourceType").to_s == "QuestionnaireResponse"
      end

      def bundle_entry_resources(document)
        Array(fhir_value(document, "entry")).filter_map do |entry|
          resource = fhir_value(entry, "resource")
          resource if resource.is_a?(Hash)
        end
      end

      def instrument_for(resource)
        canonical = fhir_value(resource, "questionnaire").to_s
        ScreeningInstrument::ALL.find { |instrument| instrument.questionnaire_canonical == canonical }
      end

      def screening_total(resource, instrument)
        value = extension_value(resource, SCREENING_SCORE_EXT, "valueInteger")
        return value.to_i if value.is_a?(Numeric)

        pairs = answered_pairs(resource, instrument)
        pairs.sum { |_item, choice| choice.value.to_i } unless pairs.empty?
      end

      def screening_band(resource, instrument, total)
        band = extension_value(resource, SCREENING_BAND_EXT, "valueString")
        return band if band.present?
        return if instrument.nil? || total.nil?

        instrument.band_label_for(total)
      end

      def safety_flag_from(resource)
        extension = extension_for(resource, SCREENING_SAFETY_EXT)
        return false unless extension

        !!fhir_value(extension, "valueBoolean")
      end

      def answered_pairs(resource, instrument)
        return [] if instrument.nil?

        Array(fhir_value(resource, "item")).filter_map { |item| answered_pair(item, instrument) }
      end

      def answered_pair(item, instrument)
        link_id = fhir_value(item, "linkId").to_s
        source = instrument.item_for(link_id)
        choice = choice_from(item)
        return if source.nil? || choice.nil?

        [ display_item(source, item), choice ]
      end

      def display_item(source, item)
        ScreeningInstrument::Item.new(
          link_id: source.link_id,
          position: source.position,
          text: fhir_value(item, "text").presence || source.text
        )
      end

      def choice_from(item)
        coding = fhir_value(first_fhir(fhir_value(item, "answer")), "valueCoding")
        code = fhir_value(coding, "code").to_s
        known = ScreeningInstrument::CHOICES.find { |choice| choice.link_id == code }
        return if known.nil?

        ScreeningInstrument::Choice.new(
          value: known.value,
          link_id: known.link_id,
          text: fhir_value(coding, "display").presence || known.text
        )
      end

      def encounter_ien_from(resource)
        reference = fhir_value(fhir_value(resource, "encounter"), "reference").to_s
        prefix, ien = reference.split("/", 2)
        ien if prefix == "Encounter" && ien.present?
      end

      def egress_time(value)
        return value if value.respond_to?(:strftime)
        return if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def extension_value(resource, url, key)
        fhir_value(extension_for(resource, url), key)
      end

      def extension_for(resource, url)
        Array(fhir_value(resource, "extension")).find { |ext| fhir_value(ext, "url") == url }
      end

      def first_fhir(value)
        value.is_a?(Array) ? value.first : value
      end

      def fhir_value(object, key)
        return unless object.is_a?(Hash)
        return object[key.to_s] if object.key?(key.to_s)

        object[key.to_sym] if object.key?(key.to_sym)
      end
    end
  end
end
