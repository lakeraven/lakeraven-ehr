# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientsController < ApplicationController
      include PatientCompartment

      before_action :enforce_patient_context!, only: :show
      before_action :enforce_patient_search_context!, only: :index
      before_action :validate_patient_search_values!, only: :index
      before_action :require_registration_scope!, only: :create

      def index
        matches = resolve_patient_search
        # Same as render_bundle / fhir_search_bundle: total is the length of
        # the whole match set, not of this page. _revinclude rows are appended
        # after the page and are not counted.
        total = matches.length
        # A sort reads FHIR elements, so a sorted search builds every match
        # before paging; an unsorted one builds only the page.
        page = if fhir_sort_keys.any?
          fhir_page(fhir_sort(matches.map(&:to_fhir)))
        else
          fhir_page(matches).map(&:to_fhir)
        end

        entries = page.map { |resource| { resource: resource, search: { mode: "match" } } }

        # _revinclude hands the caller resources of ANOTHER type, so it needs
        # that type's read scope like any other read. A `user/Patient.read`
        # token used to receive Provenance entries — including their agent
        # references — because the inclusion was never authorized.
        if params[:_revinclude] == "Provenance:target" && readable_included_types(%w[Provenance]).any?
          page.each do |resource|
            ProvenanceStore.instance.for_target("Patient", "rpms-#{resource[:id]}").each do |prov|
              entries << { resource: prov.to_fhir, search: { mode: "include" } }
            end
          end
        end

        render_fhir_egress(paged_search_bundle(entries, total: total))
      end

      def show
        patient = Patient.find_by_dfn(params[:dfn])

        if patient.nil?
          render_operation_outcome(
            status: :not_found,
            severity: "error",
            code: "not-found",
            diagnostics: "Patient not found"
          )
          return
        end

        render_fhir_egress(patient.to_fhir)
      end

      def create
        raw = request.body.read
        fhir = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          return render_operation_outcome(status: :bad_request, severity: "error",
            code: "invalid", diagnostics: "Request body is not valid JSON")
        end
        unless fhir.is_a?(Hash) && fhir["resourceType"] == "Patient"
          return render_operation_outcome(status: :bad_request, severity: "error",
            code: "invalid", diagnostics: "Request body must be a FHIR Patient resource")
        end

        reg = registration_params_from_fhir(fhir)
        result = RegistrationGateway.register(reg)

        if result[:success] && result[:dfn].to_i.positive?
          publish_created_patient(result[:dfn], reg)
        elsif result[:success]
          render_operation_outcome(status: :bad_gateway, severity: "error", code: "exception",
            diagnostics: "Registration reported success but returned no patient identifier")
        else
          render_operation_outcome(status: gateway_http_status(result[:status]),
            severity: "error", code: gateway_issue_code(result[:status]), diagnostics: result[:error])
        end
      end

      private

      def enforce_patient_context!
        authorize_patient_context!(params[:dfn])
      end

      # A patient-bound token may search only within its own compartment. An
      # unqualified search (by name, by SSN, or with no parameter at all) is a
      # cross-patient read, so a bound token cannot issue one: it must name
      # its own DFN in `_id`. Unbound (user/ or system/) tokens are unaffected.
      def enforce_patient_search_context!
        authorize_patient_search!(params[:_id])
      end

      # Registration is the one Patient interaction an IHS capability owns, so
      # a withheld bprm_registration still refuses a caller without the write
      # scope before it says the capability is missing.
      def authorize_before_unavailable!
        super
        require_registration_scope! if !performed? && action_name == "create"
      end

      def require_registration_scope!
        return if system_scope? || user_context_scope?
        render_forbidden("Patient registration requires a user- or system-level write scope")
      end

      # Every parameter given narrows the match set: FHIR search parameters
      # combine with AND. birthdate and gender used to apply only alongside
      # name, and _id discarded every other parameter, so `?birthdate=` alone
      # or `?_id=1&gender=male` returned patients the search had excluded.
      # Each parameter here is declared in FHIR::SearchCapabilities; identifier
      # is not (see there).
      def resolve_patient_search
        results = if params[:_id].present?
          patient = Patient.find_by_dfn(params[:_id])
          patient ? [ patient ] : []
        elsif params[:identifier].present?
          ssn = extract_ssn_from_identifier(params[:identifier])
          ssn ? Patient.search_by_ssn(ssn) : []
        else
          Patient.search(params[:name].to_s)
        end
        results = filter_by_name(results) if params[:name].present? && (params[:_id].present? || params[:identifier].present?)
        results = filter_by_birthdate(results) if params.key?(:birthdate)
        results = filter_by_gender(results) if params.key?(:gender)
        results
      end

      # The patients the name lookup itself would return, among these.
      def filter_by_name(patients)
        named = Patient.search(params[:name]).map { |p| p.dfn.to_s }
        patients.select { |p| named.include?(p.dfn.to_s) }
      end

      def extract_ssn_from_identifier(identifier)
        # Accept system|value format (e.g. http://hl7.org/fhir/sid/us-ssn|111-11-1111)
        parts = identifier.split("|")
        parts.length == 2 ? parts[1] : identifier
      end

      def filter_by_birthdate(patients)
        target = Date.iso8601(params[:birthdate])
        patients.select { |p| p.dob == target }
      end

      # Compared as served: PatientSerializer is what turns RPMS sex into a
      # FHIR gender, so a patient matches the gender its own resource shows.
      def filter_by_gender(patients)
        patients.select { |p| p.to_fhir[:gender] == params[:gender] }
      end

      BIRTHDATE = /\A\d{4}-\d{2}-\d{2}\z/
      GENDERS = %w[male female other unknown].freeze

      # A value these filters cannot apply is refused, not skipped: skipping
      # it answers a search the client did not send. birthdate takes one day;
      # the date prefixes (ge, lt, ...) and partial dates are not implemented.
      def validate_patient_search_values!
        if params.key?(:birthdate) && !valid_birthdate?(params[:birthdate])
          return refuse_search_parameter("birthdate", "one day, YYYY-MM-DD")
        end
        return unless params.key?(:gender) && GENDERS.exclude?(params[:gender])

        refuse_search_parameter("gender", "one of #{GENDERS.join(', ')}")
      end

      def valid_birthdate?(value)
        value.is_a?(String) && value.match?(BIRTHDATE) && Date.iso8601(value)
      rescue Date::Error
        false
      end

      SSN_SYSTEMS = [
        "http://hl7.org/fhir/sid/us-ssn",
        "urn:oid:2.16.840.1.113883.4.1"
      ].freeze

      def registration_params_from_fhir(fhir)
        name = Array(fhir["name"]).first
        name = {} unless name.is_a?(Hash)
        family = name["family"].to_s
        given = Array(name["given"]).join(" ")
        {
          name: [ family, given ].reject(&:empty?).join(","),
          sex: { "male" => "M", "female" => "F" }[fhir["gender"]],
          date_of_birth: fhir["birthDate"],
          ssn: ssn_from_identifiers(fhir["identifier"])
        }
      end

      def ssn_from_identifiers(identifiers)
        Array(identifiers).each { |i| return i["value"] if i.is_a?(Hash) && SSN_SYSTEMS.include?(i["system"]) }
        nil
      end

      # Registration has already succeeded by the time the filter refuses.
      # 503 would invite a retry that registers a second patient. Location
      # carries the new DFN; the body does not, and neither does any
      # demographic from the request. The DFN is logged server-side.
      def publish_created_patient(dfn, reg)
        filtered = filter_fhir_for_egress(created_patient_fhir(dfn, reg))
        response.headers["Location"] = "#{request.base_url}#{request.path}/#{dfn}"
        if filtered
          render json: filtered, status: :created, content_type: FHIR_CONTENT_TYPE
        else
          Rails.logger.warn("[patient] registered DFN #{dfn}; FHIR representation withheld")
          render_operation_outcome(
            status: :created,
            severity: "information",
            code: "suppressed",
            diagnostics: "The representation is withheld"
          )
        end
      end

      def created_patient_fhir(dfn, reg)
        {
          resourceType: "Patient",
          id: dfn.to_s,
          identifier: [ { system: "https://lakeraven.com/fhir/sid/dfn", value: dfn.to_s } ],
          name: patient_name_fhir(reg[:name]),
          gender: { "M" => "male", "F" => "female" }[reg[:sex]],
          birthDate: reg[:date_of_birth]
        }.compact
      end

      def patient_name_fhir(joined)
        return nil if joined.to_s.empty?
        family, given = joined.split(",", 2)
        [ { family: family, given: (given ? given.split(" ") : []) }.compact ]
      end

      def gateway_http_status(status)
        { 422 => :unprocessable_content, 409 => :conflict, 503 => :service_unavailable }
          .fetch(status, :internal_server_error)
      end

      def gateway_issue_code(status)
        { 422 => "invalid", 409 => "conflict", 503 => "transient" }.fetch(status, "exception")
      end
    end
  end
end
