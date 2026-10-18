# frozen_string_literal: true

module Lakeraven
  module EHR
    # Read-only demo patient chart (issue #452), AUTHENTICATED with a
    # dev-only demo bypass.
    #
    # Inherits ActionController::Base (needed to render the HTML view) rather
    # than the engine's ActionController::API FHIR base, but reuses the SAME
    # protections the FHIR controllers apply, enforced for BOTH the HTML and
    # the FHIR-JSON paths and FAILING CLOSED:
    #   * SmartAuthentication — Doorkeeper bearer token required.
    #   * Per-resource read scope — the chart aggregates many resource types;
    #     it requires `Patient` read scope (else 403 for the whole request)
    #     and OMITS any individual section the token cannot read.
    #   * Patient-context binding — a patient-scoped token is bound to :dfn.
    #   * AuditableClinicalAccess — every authenticated access is audited.
    #
    # Unauthorized/forbidden responses are FORMAT-AWARE: FHIR requests get an
    # OperationOutcome (application/fhir+json); HTML requests get plain text.
    #
    # Demo bypass: authentication is skipped ONLY when
    #   Rails.env.development? && CHART_DEMO_OPEN=1 && SPIKE_MOCK_RPC=1
    # so the local synthetic demo opens with no token. The `development?` guard
    # makes the bypass impossible in test or production, and the mock-RPC guard
    # keeps it from ever fronting a real backend. Host browser-session
    # -> token SSO is a documented follow-up (ADR 0004), out of scope here.
    #
    # ONE endpoint, content-negotiated:
    #   GET /patients/:dfn         -> clinician-facing HTML chart
    #   GET /patients/:dfn.json    -> FHIR R4 Bundle (searchset)
    #   Accept: application/fhir+json / ?_format=json also yield the Bundle
    #
    # Data flows through the engine's real gateways/models + `.to_fhir`
    # serializers; only the RPMS data source is mocked (see
    # test/dummy/lib/lakeraven_demo_seeds.rb).
    class ChartsController < ActionController::Base
      include SmartAuthentication
      # FAIL-CLOSED audit, the same terms the clinician screening surface is
      # held to. The chart now carries scored screenings (#474), so it serves
      # the same item-level self-harm disclosures — and a sibling route to the
      # same bytes must not be the one with the weaker audit. Since #512 the
      # shared concern IS the fail-closed one: if the access cannot be
      # recorded, it is not completed.
      include AuditableClinicalAccess
      include FHIRReadEgress

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_chart_request!
      before_action :require_patient_scope!
      before_action :enforce_patient_context!

      # ORWPT APPTLST status text -> FHIR Encounter.status
      APPOINTMENT_STATUS = {
        "scheduled" => "planned", "checked in" => "arrived",
        "checked out" => "finished", "cancelled" => "cancelled",
        "no show" => "cancelled"
      }.freeze
      # Encounter.status is the FHIR code. The HTML chart shows the RPMS
      # text, which has to ride on the resource the filter returns.
      RPMS_APPOINTMENT_STATUS = "https://lakeraven.com/fhir/StructureDefinition/rpms-appointment-status"

      # Screening row the HTML chart reads back out of a filtered Observation.
      ChartScreening = Struct.new(
        :effective_at, :instrument, :total_score, :severity_band,
        keyword_init: true
      ) do
        def severity_slug
          severity_band.to_s.parameterize
        end
      end

      def show
        @patient = Patient.find_by_dfn(params[:dfn])
        return render_missing_patient unless @patient

        load_clinical_collections
        render_chart
      end

      private

      # -- Authentication / authorization (fail closed) -------------------------

      # Dev-only escape hatch so tomorrow's LOCAL demo opens with no token.
      # Guarded on development? so it can NEVER apply in test or production,
      # and on the mock-RPC flag so it can never expose a real backend.
      def demo_bypass?
        Rails.env.development? && ENV["CHART_DEMO_OPEN"] == "1" && ENV["SPIKE_MOCK_RPC"] == "1"
      end

      # THE ONE surface that may authenticate a browser SESSION token. This is
      # the server-rendered HTML chart (ActionController::Base, BFF-style); a
      # signed-in clinician reaches it with no Authorization header, so it reads
      # the SMART token the sign-on bridge stashed in the session. The FHIR API
      # (ActionController::API) stays bearer-only — see
      # SmartAuthentication#session_token_fallback_allowed? and #512 F1 / #525.
      def session_token_fallback_allowed?
        true
      end

      def authenticate_chart_request!
        return true if demo_bypass?

        authenticate_smart_token! # renders 401 (format-aware) + halts on failure
      end

      # The chart always includes Patient demographics; without Patient read
      # scope there is nothing safe to show -> deny the whole request.
      def require_patient_scope!
        return true if demo_bypass?
        return true if can_read?("Patient")

        render_forbidden("Insufficient scope to read Patient")
        false
      end

      def enforce_patient_context!
        return true if demo_bypass?

        authorize_patient_context!(params[:dfn]) # renders 403 (format-aware) on mismatch
      end

      # True when the caller is permitted to see a given resource type. The
      # dev bypass grants everything; otherwise it defers to the token scopes.
      def readable?(resource_type)
        demo_bypass? || can_read?(resource_type)
      end

      # AuditableClinicalAccess records entity_type from this; the chart is a
      # Patient-centric aggregate, so audit it against Patient + the dfn.
      # The dfn is the route segment. `params` also carries the query string,
      # so `?id=` or `?dfn=` must not name a record this chart did not open.
      def fhir_resource_type
        "Patient"
      end

      # The route may say "01". The chart shows the patient the repository
      # resolves, and the audit row names that same canonical dfn.
      def direct_audit_identifier
        Patient.canonical_dfn(chart_route_dfn) || chart_route_dfn || super
      end

      def chart_route_dfn
        path = request.path_parameters
        path[:dfn].presence || path["dfn"].presence
      end

      # AuditableClinicalAccess hook: demo-bypass requests carry no token but
      # must still leave an audit trail, under a dedicated fixed service actor
      # (independent security review finding). The entity identifier stays the
      # route dfn — no additional PHI enters the log.
      def unauthenticated_audit_actor
        "demo-bypass" if demo_bypass?
      end

      # -- Content negotiation --------------------------------------------------

      def fhir_requested?
        return true if params[:format].to_s == "json"
        return true if params[:_format].to_s == "json"

        request.headers["Accept"].to_s.include?("application/fhir+json")
      end

      # -- Data loading (per-type scope enforced; a mock miss yields []) --------

      def load_clinical_collections
        dfn = @patient.dfn.to_s
        @conditions    = readable?("Condition") ? build_conditions(dfn) : []
        @medications   = readable?("MedicationRequest") ? build_medications(dfn) : []
        @allergies     = build_allergies(dfn)
        # Through the seam, like the FHIR search: converting the raw vitals here
        # would stamp this patient's DFN over whatever a row stated, and would
        # omit a configured supplemental provider's rows from the chart while
        # showing them in the search.
        @observations  = readable?("Observation") ? safe { SupplementalClinicalResources.merged_observations_for_patient(dfn) } || [] : []
        @immunizations = readable?("Immunization") ? safe { Immunization.for_patient(dfn) } : []
        @procedures    = readable?("Procedure") ? build_procedures(dfn) : []
        @encounters    = readable?("Encounter") ? safe { EncounterGateway.for_patient(dfn) } : []
        @encounter_resources = build_encounter_resources(dfn)
        load_screenings(dfn)
      end

      # Scored screening instruments (#474). Engine-owned records rather than an
      # RPMS read, and they yield TWO resource families with different
      # sensitivities:
      #
      #   * the total score        -> Observation           (Observation scope)
      #   * the item-level answers -> QuestionnaireResponse  (QR scope)
      #
      # The two are authorized INDEPENDENTLY. A token with QuestionnaireResponse
      # scope but no Observation scope still gets the answers, and vice versa —
      # neither family may be reachable only via the other's scope. One query
      # feeds both; it is skipped entirely when neither scope is held.
      # A screening row is engine-owned side data. If one of them cannot be
      # rendered or serialized, that must cost AT MOST that row — never the
      # Patient, Conditions, Medications, Allergies and Vitals that the chart
      # exists for. `safe` wrapped only the QUERY, so a single out-of-range
      # ordinal (serializer -> nil choice -> NoMethodError) 500'd the whole
      # bundle. Rows whose instrument no longer exists are dropped up front;
      # anything else that raises is dropped per row by `safe_map`.
      def load_screenings(dfn)
        wants_scores  = readable?("Observation")
        wants_answers = readable?("QuestionnaireResponse")
        screenings = if wants_scores || wants_answers
                       publishable_screenings(safe { ScreeningResponse.for_patient(dfn) })
        else
                       []
        end

        @screenings = wants_scores ? screenings : []
        @screening_observations = safe_map(@screenings, &:to_observation)
        @screening_answers = wants_answers ? screenings : []
      end

      # Validation runs on WRITE; this is the read side of the same contract.
      # A row that does not satisfy its own invariants — a total that is not
      # its answers' sum, a self-harm disclosure with no acknowledgement, an
      # instrument that no longer exists — is SKIPPED rather than published as
      # a `completed` QuestionnaireResponse or a `final` Observation. Those
      # statuses are assertions, and this row cannot support them. It is never
      # repaired here: inventing the missing half is the failure being guarded
      # against.
      def publishable_screenings(screenings)
        screenings.select do |screening|
          next true if screening.publishable?

          Rails.logger.warn("[chart] screening #{screening.id} withheld: fails its own invariants")
          false
        end
      end

      def build_conditions(dfn)
        safe { Condition.for_patient(dfn) }.map { |h| Condition.from_rpms_row(h, patient_dfn: dfn) }
      end

      def build_medications(dfn)
        safe { MedicationRequest.for_patient(dfn) }.map { |h| MedicationRequest.from_rpms_row(h, patient_dfn: dfn) }
      end

      # `status` has a REQUIRED binding in FHIR. RPMS status text like
      # "ACTIVE"/"DISCONTINUED" must never pass through raw: normalize to
      # lowercase, keep it only if it is a legal code, else fall back.
      def valid_status(raw, valid, fallback)
        normalized = raw.to_s.strip.downcase
        valid.include?(normalized) ? normalized : fallback
      end

      # Through the shared normalizer, so this bundle and the FHIR search cannot
      # disagree about the same wire row -- they previously read different keys
      # for the reaction -- and so a configured supplemental provider's rows are
      # in the chart rather than only in the search.
      #
      # Not `safe`. That helper turns a raise and a real [] into the same [],
      # and the banner then cannot tell "not loaded" from "none recorded".
      # Other sections still use `safe`.
      def build_allergies(dfn)
        @allergy_source = chart_allergy_source(dfn)
        @allergy_source.records
      end

      def chart_allergy_source(dfn)
        return AllergySource.unauthorized unless readable?("AllergyIntolerance")

        AllergySource.fetch(log_label: "[chart]") do
          SupplementalClinicalResources.merged_allergy_intolerances_for_patient(dfn)
        end
      end

      # ORQQAL LIST (the allergy RPC) returns ALLERGEN^REACTION^SEVERITY with no
      # IEN, so these records carry no natural identifier. Prefer a real IEN if
      # one ever appears; otherwise derive a DETERMINISTIC id from dfn + allergen
      # so AllergyIntolerance#to_fhir emits a stable, resolvable fullUrl (never
      # random/urn:uuid). AllergyIntolerance#to_fhir turns this into `id`.
      def allergy_id(dfn, hash)
        hash[:ien].to_s.presence || "allergy-#{dfn}-#{hash[:allergen].to_s.parameterize}"
      end

      def build_procedures(dfn)
        safe { Procedure.for_patient(dfn) }.map do |h|
          Procedure.new(
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            display: h[:name],
            status: valid_status(h[:status], Procedure::VALID_STATUSES, "completed"),
            performed_datetime: h[:date]
          )
        end
      end

      def build_encounter_resources(dfn)
        @encounters.map do |h|
          Encounter.new(
            status: APPOINTMENT_STATUS[h[:status].to_s.downcase] || "planned",
            class_code: "AMB", period_start: h[:datetime],
            patient_identifier: dfn, location_ien: h[:location_ien]
          )
        end
      end

      def safe
        Array(yield)
      rescue => e
        Rails.logger.warn("[chart] clinical fetch failed: #{e.class}: #{e.message}")
        []
      end

      # Per-record projection boundary: one record that cannot be projected is
      # skipped, the rest of the collection survives, and the request does not
      # 500. Used where the projection is derived from stored data rather than
      # fetched (screenings), since a bad row is otherwise indistinguishable
      # from a bad chart.
      def safe_map(records)
        records.filter_map do |record|
          yield record
        rescue => e
          Rails.logger.warn("[chart] record #{record.class}##{record.id} skipped: #{e.class}: #{e.message}")
          nil
        end
      end

      # -- FHIR Bundle ----------------------------------------------------------

      def fhir_bundle
        resources = [ @patient.to_fhir ]
        resources.concat(@conditions.map(&:to_fhir))
        resources.concat(@medications.map(&:to_fhir))
        resources.concat(@allergies.map(&:to_fhir))
        resources.concat(@observations.map(&:to_fhir))
        resources.concat(safe_map(@screening_observations, &:to_fhir))
        resources.concat(safe_map(@screening_answers, &:to_questionnaire_response))
        resources.concat(@immunizations.map(&:to_fhir))
        resources.concat(@procedures.map(&:to_fhir))
        resources.concat(chart_encounter_entries)

        {
          resourceType: "Bundle",
          id: SecureRandom.uuid,
          meta: { lastUpdated: Time.current.iso8601 },
          type: "searchset",
          total: resources.length,
          link: [ { relation: "self", url: request.original_url } ],
          entry: resources.map do |r|
            { fullUrl: entry_full_url(r), resource: r, search: { mode: "match" } }
          end
        }
      end

      # Chart appointments (ORWPT APPTLST) carry no visit IEN, so the derived
      # Encounter has no natural id. Derive a DETERMINISTIC, stable id from the
      # patient dfn + appointment start (not random/urn:uuid) so the same
      # appointment yields the same resolvable fullUrl on every request. If a
      # real visit IEN ever flows through, Encounter#to_fhir uses it and this
      # fallback is skipped.
      #
      # APPTLST datetimes are date-only, so distinct appointments on the same
      # day compute the same fallback. chart_encounter_entries counts those
      # fallbacks and passes fallback_id only when that value belongs to one
      # Encounter in the bundle. When the same fallback would be used by more
      # than one Encounter, it is not set on any of them (fail closed);
      # entry_full_url then gives each a urn:uuid. A unique fallback keeps its
      # id. An Encounter whose to_fhir already returned an id is unchanged.
      def encounter_to_fhir(encounter, source = {}, fallback_id: nil)
        fhir = encounter.to_fhir
        assign_fallback_encounter_id(fhir, fallback_id)
        stamp_location_display(fhir, source[:location] || source["location"])
        stamp_rpms_status(fhir, source[:status] || source["status"])
        fhir
      end

      def assign_fallback_encounter_id(fhir, fallback_id)
        return if fhir[:id].present?
        return if fallback_id.blank?

        fhir[:id] = fallback_id
      end

      def appointment_fhir_id(encounter)
        "appt-#{encounter.patient_identifier}-#{encounter.period_start&.strftime("%Y%m%d%H%M")}"
      end

      def stamp_rpms_status(fhir, status_text)
        return if status_text.blank?

        fhir[:extension] = Array(fhir[:extension]) + [ {
          url: RPMS_APPOINTMENT_STATUS,
          valueString: status_text.to_s
        } ]
      end

      def stamp_location_display(fhir, name)
        return if name.blank?

        locations = fhir[:location] || fhir["location"]
        locations = fhir[:location] = [ { location: {} } ] if locations.blank?
        locations.each do |entry|
          place = entry[:location] || entry["location"]
          place[:display] = name if place.is_a?(Hash)
        end
      end

      def chart_encounter_entries
        rows = encounter_fallback_rows
        counts = fallback_id_counts(rows)
        rows.map do |row|
          encounter_to_fhir(row[:encounter], row[:source], fallback_id: sole_fallback_id(row[:fallback], counts))
        end
      end

      def encounter_fallback_rows
        @encounters.zip(@encounter_resources).map do |source, encounter|
          { source: source, encounter: encounter, fallback: appointment_fallback_for(encounter) }
        end
      end

      # Appointment-derived Encounters are those Encounter#to_fhir left without
      # an id. A real visit IEN is already on the resource and is not a fallback.
      def appointment_fallback_for(encounter)
        return if encounter.to_fhir[:id].present?

        appointment_fhir_id(encounter)
      end

      def fallback_id_counts(rows)
        rows.filter_map { |row| row[:fallback] }.tally
      end

      def sole_fallback_id(fallback, counts)
        return if fallback.blank?
        return if counts[fallback] > 1

        fallback
      end

      def render_chart
        if fhir_requested?
          render_fhir_egress(fhir_bundle)
        else
          render_html_chart
        end
      end

      # The page is the filtered bundle. Loader collections are only the input
      # to fhir_bundle; they are not what the template renders.
      def render_html_chart
        bundle = filter_fhir_for_egress(fhir_bundle)
        return refuse_unfiltered_fhir_egress unless bundle

        assign_chart_from_bundle(bundle)
        assign_patient_banner
        render :show, layout: false
      end

      # The banner and the allergy sections both read the filtered bundle.
      # Source status is what tells a withheld list from a genuinely empty one.
      def assign_patient_banner
        @allergy_list_status = chart_allergy_status
        @patient_banner = PatientBanner.for_chart(@patient, @allergy_list_status)
      end

      def chart_allergy_status
        @allergy_source.to_list_status(@allergies.map(&:display_allergen))
      end

      def assign_chart_from_bundle(bundle)
        grouped = resources_by_type(bundle)
        observations = grouped["Observation"]
        @patient = chart_patient(grouped["Patient"]&.first)
        @conditions = chart_conditions(grouped["Condition"])
        @medications = chart_medications(grouped["MedicationRequest"])
        @allergies = chart_allergies(grouped["AllergyIntolerance"])
        @vitals = chart_vitals(observations)
        @immunizations = chart_immunizations(grouped["Immunization"])
        @encounters = chart_encounters(grouped["Encounter"])
        @screenings = chart_screenings(observations)
      end

      def resources_by_type(bundle)
        bundle_resources(bundle).group_by { |resource| fhir_field(resource, "resourceType").to_s }
      end

      def bundle_resources(bundle)
        fhir_list(fhir_field(bundle, "entry")).filter_map do |entry|
          resource = fhir_field(entry, "resource")
          resource if resource.is_a?(Hash)
        end
      end

      def chart_patient(resource)
        return Patient.new(dfn: params[:dfn]) if resource.nil?

        Patient.from_fhir(stringify_fhir(resource))
      end

      def stringify_fhir(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, inner), copy| copy[key.to_s] = stringify_fhir(inner) }
        when Array
          value.map { |inner| stringify_fhir(inner) }
        else
          value
        end
      end

      def chart_conditions(resources)
        fhir_list(resources).map { |resource| condition_from_fhir(resource) }
      end

      def condition_from_fhir(resource)
        code = fhir_field(resource, "code")
        Condition.new(
          display: codeable_text(code),
          code: fhir_coding_code(code),
          clinical_status: fhir_coding_code(fhir_field(resource, "clinicalStatus"))
        )
      end

      def chart_medications(resources)
        fhir_list(resources).map { |resource| medication_from_fhir(resource) }
      end

      def medication_from_fhir(resource)
        dose = fhir_first(fhir_field(resource, "dosageInstruction"))
        MedicationRequest.new(
          medication_display: codeable_text(fhir_field(resource, "medicationCodeableConcept")),
          dosage_instruction: fhir_field(dose, "text"),
          status: fhir_field(resource, "status")
        )
      end

      def chart_allergies(resources)
        fhir_list(resources).map { |resource| allergy_from_fhir(resource) }
      end

      def allergy_from_fhir(resource)
        code = fhir_field(resource, "code")
        reaction = fhir_first(fhir_field(resource, "reaction"))
        manifestation = fhir_first(fhir_field(reaction, "manifestation"))
        AllergyIntolerance.new(
          allergen: codeable_text(code),
          allergen_code: fhir_coding_code(code),
          reaction: fhir_field(manifestation, "text"),
          severity: fhir_field(reaction, "severity")
        )
      end

      def chart_immunizations(resources)
        fhir_list(resources).map { |resource| immunization_from_fhir(resource) }
      end

      def immunization_from_fhir(resource)
        Immunization.new(
          vaccine_display: codeable_text(fhir_field(resource, "vaccineCode")),
          occurrence_datetime: parse_fhir_time(fhir_field(resource, "occurrenceDateTime")),
          status: fhir_field(resource, "status")
        )
      end

      def chart_encounters(resources)
        fhir_list(resources).map { |resource| encounter_row_from_fhir(resource) }
      end

      def encounter_row_from_fhir(resource)
        location = fhir_first(fhir_field(resource, "location"))
        {
          datetime: parse_fhir_time(fhir_field(fhir_field(resource, "period"), "start")),
          location: fhir_field(fhir_field(location, "location"), "display"),
          status: rpms_status_text(resource) || fhir_field(resource, "status")
        }
      end

      def rpms_status_text(resource)
        extension = fhir_list(fhir_field(resource, "extension")).find do |ext|
          fhir_field(ext, "url") == RPMS_APPOINTMENT_STATUS
        end
        fhir_field(extension, "valueString").presence
      end

      def chart_vitals(observations)
        fhir_list(observations).filter_map { |resource| vital_row_from_fhir(resource) }
      end

      def vital_row_from_fhir(resource)
        return unless observation_category(resource) == "vital-signs"

        code = fhir_coding_code(fhir_field(resource, "code"))
        type = vital_type_for(code)&.first
        type = codeable_text(fhir_field(resource, "code")) if type.nil?
        return if type.blank?

        { type: type, value: vital_display_value(resource, code), units: vital_units_from(resource) }
      end

      # The unit RPMS recorded, from valueQuantity.unit. Blood pressure has no
      # top-level quantity; the same recorded unit is on each component.
      def vital_units_from(resource)
        stated = fhir_field(fhir_field(resource, "valueQuantity"), "unit")
        return stated unless stated.nil?

        component_unit(resource)
      end

      def component_unit(resource)
        component = fhir_first(fhir_field(resource, "component"))
        fhir_field(fhir_field(component, "valueQuantity"), "unit")
      end

      def vital_type_for(code)
        Observation::VITAL_TYPE_MAP.find { |_type, mapping| mapping[:code] == code }
      end

      def vital_display_value(resource, code)
        displayed = if code == Observation::VITAL_SIGNS_CODES[:blood_pressure]
          blood_pressure_reading(resource)
        else
          quantity = fhir_field(fhir_field(resource, "valueQuantity"), "value")
          format_fhir_number(quantity) unless quantity.nil?
        end
        return displayed unless displayed.nil?

        fhir_field(resource, "valueString").presence
      end

      def blood_pressure_reading(resource)
        components = fhir_list(fhir_field(resource, "component"))
        systolic = component_quantity(components, Observation::VITAL_SIGNS_CODES[:systolic])
        diastolic = component_quantity(components, Observation::VITAL_SIGNS_CODES[:diastolic])
        return if systolic.nil? || diastolic.nil?

        "#{format_fhir_number(systolic)}/#{format_fhir_number(diastolic)}"
      end

      def component_quantity(components, code)
        match = components.find { |component| fhir_coding_code(fhir_field(component, "code")) == code }
        fhir_field(fhir_field(match, "valueQuantity"), "value")
      end

      def format_fhir_number(value)
        number = Float(value)
        (number % 1).zero? ? number.to_i.to_s : number.to_s
      rescue ArgumentError, TypeError
        value.to_s
      end

      def chart_screenings(observations)
        fhir_list(observations).filter_map { |resource| screening_from_fhir(resource) }
      end

      def screening_from_fhir(resource)
        return unless observation_category(resource) == "survey"

        instrument = screening_instrument_for(resource)
        total = screening_total(resource)
        effective_at = parse_fhir_time(fhir_field(resource, "effectiveDateTime"))
        return if instrument.nil? || total.nil? || effective_at.nil?

        ChartScreening.new(
          effective_at: effective_at,
          instrument: instrument,
          total_score: total,
          severity_band: instrument.band_label_for(total).to_s
        )
      end

      def screening_instrument_for(resource)
        code = fhir_coding_code(fhir_field(resource, "code"))
        ScreeningInstrument::ALL.find { |instrument| instrument.total_score_code == code }
      end

      def screening_total(resource)
        value = fhir_field(fhir_field(resource, "valueQuantity"), "value")
        number = Float(value)
        (number % 1).zero? ? number.to_i : number
      rescue ArgumentError, TypeError
        nil
      end

      def observation_category(resource)
        fhir_coding_code(fhir_first(fhir_field(resource, "category")))
      end

      def codeable_text(codeable)
        text = fhir_field(codeable, "text")
        return text if text.present?

        fhir_field(fhir_first(fhir_field(codeable, "coding")), "display")
      end

      def fhir_coding_code(codeable)
        fhir_field(fhir_first(fhir_field(codeable, "coding")), "code")
      end

      def fhir_first(value)
        value.is_a?(Array) ? value.first : value
      end

      def fhir_list(value)
        case value
        when nil then []
        when Array then value
        else [ value ]
        end
      end

      def fhir_field(object, key)
        return unless object.is_a?(Hash)
        return object[key.to_s] if object.key?(key.to_s)

        object[key.to_sym] if object.key?(key.to_sym)
      end

      def parse_fhir_time(value)
        return if value.blank?
        return value if value.respond_to?(:strftime)

        text = value.to_s
        text.include?("T") ? Time.iso8601(text) : Date.iso8601(text).to_time
      rescue ArgumentError, TypeError
        nil
      end

      # Absolute fullUrl for a resource. Resources whose serializer emits an id
      # get a REST URL under the engine's ACTUAL mount point (previously the
      # hardcoded `/fhir/` prefix pointed at a path that doesn't exist);
      # resources without an id get a valid urn:uuid so the Bundle stays
      # FHIR-conformant.
      def entry_full_url(resource)
        id = resource[:id]
        if id.present?
          "#{request.base_url}#{engine_mount_path}/#{resource[:resourceType]}/#{id}"
        else
          "urn:uuid:#{SecureRandom.uuid}"
        end
      end

      # Path where the host app mounted the engine (e.g. "/lakeraven-ehr" in
      # test/dummy). Falls back to "" (host root) if the host defined the
      # engine's routes without mounting it under a prefix.
      def engine_mount_path
        @engine_mount_path ||=
          main_app.respond_to?(:lakeraven_ehr_path) ? main_app.lakeraven_ehr_path : ""
      end

      # -- Format-aware auth failures (override SmartAuthentication) -------------
      #
      # SmartAuthentication#render_unauthorized/#render_forbidden emit FHIR JSON
      # unconditionally. A browser hitting the HTML chart should get plain text,
      # not a FHIR OperationOutcome — so branch on the requested representation.

      def render_unauthorized(message = "Unauthorized")
        render_auth_outcome(:unauthorized, "login", message)
      end

      def render_forbidden(message = "Forbidden")
        render_auth_outcome(:forbidden, "forbidden", message)
      end

      def render_auth_outcome(status, code, message)
        note_audit_denial(message)
        if fhir_requested?
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "error", code: code, diagnostics: message } ]
          }, status: status, content_type: FHIR_CONTENT_TYPE
        else
          render plain: "#{status.to_s.titleize}: #{message}", status: status
        end
      end

      # AuditableClinicalAccess hook: a FHIR caller gets an OperationOutcome
      # rather than plain text, like every other refusal on this controller.
      # The chart establishes no state, so there is nothing to roll back.
      def render_unrecorded_access_denial
        if fhir_requested?
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "error", code: "transient",
                       diagnostics: UNRECORDED_ACCESS_MESSAGE } ]
          }, status: :service_unavailable, content_type: FHIR_CONTENT_TYPE
        else
          render plain: "Service Unavailable: #{UNRECORDED_ACCESS_MESSAGE}",
                 status: :service_unavailable
        end
      end

      # -- 404 ------------------------------------------------------------------

      def render_missing_patient
        if fhir_requested?
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "error", code: "not-found",
                       diagnostics: "Patient/#{params[:dfn]} not found" } ]
          }, status: :not_found, content_type: FHIR_CONTENT_TYPE
        else
          render plain: "Patient #{params[:dfn]} not found", status: :not_found
        end
      end
    end
  end
end
