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

      # What the HTML pages read back out of a filtered screening bundle.
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

        @response = screening_pages(filtered).first
        @instrument = @response&.instrument
      end

      private

      # The notice is a status, not a copy of the score. Show renders the
      # total and the band only from the filtered bundle; putting them in
      # the flash would publish a total the filter removed. A replay still
      # has to say that nothing new was stored — "recorded" for a submission
      # that wrote nothing is how a discarded administration goes unnoticed.
      def outcome_notice
        if @result.duplicate?
          "#{@instrument.short_title} was already recorded. Nothing was recorded again."
        else
          "Screening recorded."
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
      # patient's screening. The id is the route segment, or the record a
      # create just stored. `params` also carries the query string and the
      # form body, so an `id` there must not name a screening this page did
      # not open. The reference rule itself (both halves derived together,
      # sanitized) lives in the shared concern since #512.
      def fhir_resource_type = audited_screening_id ? SCREENING_RESOURCE : "Patient"

      # A digit-string dfn is canonicalised the way the repository resolves
      # it, so a route of "01" audits as the patient the banner shows. A
      # screening id is not a dfn and is recorded unchanged.
      def direct_audit_identifier
        audited_screening_id || Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      # On a create the id exists only once the action has run — the audit row
      # is written after `yield`, inside the same transaction, so the new
      # record can name itself. A page with no :id segment — the history, the
      # new form, a refused create — has none, and the patient is audited.
      def audited_screening_id
        return @result.record.id.to_s if @result&.record

        route_param(:id)
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
      # Index and show hand the resources a screening already maps to
      # (QuestionnaireResponse and its score Observation) to Part2EgressFilter
      # and render only the entries that come back. An empty bundle is a page
      # with no answers and no score. Nil or an unusable payload is a 503.

      def screening_bundle(records)
        resources = records.flat_map(&:to_fhir_resources)
        {
          resourceType: "Bundle",
          type: "searchset",
          total: resources.length,
          entry: resources.map { |resource| { resource: resource } }
        }
      end

      def screening_pages(document)
        resources = document_resources(document)
        observations = resources.select { |resource| resource_type(resource) == "Observation" }
        resources.select { |resource| resource_type(resource) == "QuestionnaireResponse" }.filter_map do |resource|
          screening_page(resource, observations)
        end
      end

      def screening_page(resource, observations)
        fields = screening_page_fields(resource, observations)
        ScreeningPage.new(**fields) if fields
      end

      # The score and the band come only from the score Observation that
      # survived the filter. Summing the answers that remain invents a
      # total the filter removed. A page with no score Observation still
      # renders; the score and the band are withheld.
      def screening_page_fields(resource, observations)
        instrument = instrument_for(resource)
        return if instrument.nil?

        pairs = answered_pairs(resource, instrument)
        effective_at = egress_time(fhir_value(resource, "authored"))
        return if effective_at.nil?

        total = observation_score(resource, instrument, observations)
        band = instrument.band_label_for(total) unless total.nil?
        return if !total.nil? && band.blank?

        {
          id: fhir_value(resource, "id"),
          effective_at: effective_at,
          instrument: instrument,
          total_score: total,
          severity_band: band,
          encounter_ien: encounter_ien_from(resource),
          answered_items: pairs,
          safety_flagged: filtered_safety_flag(resource, instrument)
        }
      end

      def document_resources(document)
        if resource_type(document) == "Bundle"
          bundle_entry_resources(document)
        else
          [ document ]
        end
      end

      def resource_type(resource)
        fhir_value(resource, "resourceType").to_s
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

      def observation_score(questionnaire, instrument, observations)
        return if instrument.nil?

        id = "screening-#{instrument.key}-#{fhir_value(questionnaire, "id")}"
        match = observations.find { |observation| fhir_value(observation, "id").to_s == id }
        quantity_number(match)
      end

      def quantity_number(resource)
        return if resource.nil?

        number = Float(fhir_value(fhir_value(resource, "valueQuantity"), "value"))
        (number % 1).zero? ? number.to_i : number
      rescue ArgumentError, TypeError
        nil
      end

      # The banner follows item 9 in the filtered bundle, not the stored
      # flag and not a second read of ScreeningResponse. A missing item is
      # not a negative screen: nothing is shown. Shown only when that item
      # is present and its answer value is nonzero.
      def filtered_safety_flag(resource, instrument)
        ordinal = filtered_safety_ordinal(resource, instrument)
        !ordinal.nil? && !ordinal.zero?
      end

      def filtered_safety_ordinal(resource, instrument)
        link_id = instrument.safety_link_id
        return if link_id.blank?

        item = Array(fhir_value(resource, "item")).find do |entry|
          fhir_value(entry, "linkId").to_s == link_id
        end
        safety_answer_ordinal(item) if item
      end

      # valueInteger, when the filtered answer carries one (including zero),
      # is the answer value. Otherwise the value is the LOINC choice ordinal
      # this app writes on valueCoding.
      def safety_answer_ordinal(item)
        answer = first_fhir(fhir_value(item, "answer"))
        return unless answer.is_a?(Hash)

        if answer.key?("valueInteger") || answer.key?(:valueInteger)
          return Integer(fhir_value(answer, "valueInteger"), exception: false)
        end

        choice_from(item)&.value
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

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
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
