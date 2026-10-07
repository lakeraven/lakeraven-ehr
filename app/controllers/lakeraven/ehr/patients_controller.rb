# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientsController < ApplicationController
      # Org-bound credentials: #show authorizes the RESOLVED patient; #index
      # filters the resolved result set by organization below. #create stays
      # undeclared — DENIED to org-bound credentials — because registration
      # would write into a site the credential's binding cannot vouch for;
      # opening it needs an explicit org-match rule first.
      organization_scope :resolved_patient, only: :show, dfn_param: :dfn
      organization_scope :result_filtered, only: :index

      before_action :enforce_patient_context!, only: :show
      skip_before_action :authorize_fhir_scope!, only: :create
      before_action :authorize_fhir_write_scope!, only: :create
      before_action :require_registration_scope!, only: :create

      def index
        patients = begin
          resolve_patient_search
        rescue UnsupportedIdentifierSystem => e
          return render_operation_outcome(
            status: :bad_request, severity: "error", code: "not-supported",
            diagnostics: "Unsupported Patient.identifier system: #{e.message}"
          )
        end
        # Org-bound backend credentials only see their own organization's
        # patients (SmartAuthentication — partner conformance item 2).
        patients = patients.select { |p| org_visible_patient?(p) } if organization_bound?

        entries = patients.map { |p| build_patient_entry(p) }

        if params[:_revinclude] == "Provenance:target" && can_read?("Provenance")
          patients.each do |p|
            ProvenanceStore.instance.for_target("Patient", "rpms-#{p.dfn}").each do |prov|
              entries << { resource: prov.to_fhir, search: { mode: "include" } }
            end
          end
        end

        render json: {
          resourceType: "Bundle", type: "searchset",
          total: entries.length, entry: entries
        }, status: :ok, content_type: FHIR_CONTENT_TYPE
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

        render_fhir(patient.to_fhir)
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
          response.headers["Location"] = "#{request.base_url}#{request.path}/#{result[:dfn]}"
          render_fhir(created_patient_fhir(result[:dfn], reg), status: :created)
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

      def require_registration_scope!
        return if system_scope? || user_context_scope?
        render_forbidden("Patient registration requires a user- or system-level write scope")
      end

      def resolve_patient_search
        if params[:_id].present?
          patient = Patient.find_by_dfn(params[:_id])
          patient ? [ patient ] : []
        elsif params[:identifier].present?
          identifier_search(params[:identifier])
        elsif params[:name].present?
          results = Patient.search(params[:name])
          results = filter_by_birthdate(results) if params[:birthdate].present?
          results = filter_by_gender(results) if params[:gender].present?
          results
        else
          Patient.search("")
        end
      end

      # US Core requires `identifier` as a Patient search parameter, and a
      # search parameter must answer the question it was asked. The previous
      # implementation split on "|", discarded the SYSTEM and searched SSN, so a
      # client searching any other identifier system received 200 with an empty
      # bundle -- the server reporting "no such patient" about a lookup it never
      # performed. An unknown system is now refused, because a false negative on
      # a patient lookup is the most expensive answer this endpoint can give.
      #
      # Raises UnsupportedIdentifierSystem, which `index` renders as a 400
      # OperationOutcome with issue code `not-supported`.
      DFN_IDENTIFIER_SYSTEM = "urn:oid:2.16.840.1.113883.4.349"
      SSN_IDENTIFIER_SYSTEMS = [
        "http://hl7.org/fhir/sid/us-ssn",
        "urn:oid:2.16.840.1.113883.4.1"
      ].freeze

      class UnsupportedIdentifierSystem < StandardError; end

      def identifier_search(token)
        system, value = split_identifier(token)

        case system
        when nil
          bare_identifier_search(value)
        when DFN_IDENTIFIER_SYSTEM
          patient = Patient.find_by_dfn(value)
          patient ? [ patient ] : []
        when *SSN_IDENTIFIER_SYSTEMS
          Patient.search_by_ssn(value)
        when Lakeraven::EHR.configuration.mrn_identifier_system
          Patient.search_by_mrn(value)
        else
          raise UnsupportedIdentifierSystem, system
        end
      end

      # FHIR R4 token search is explicit that `identifier=[code]` matches
      # `Identifier.value` irrespective of the system property. A bare value is
      # therefore resolved against every system this endpoint recognises and the
      # union returned, rather than guessed at as one of them. The previous
      # implementation searched SSN alone, so a caller presenting a known MRN or
      # DFN without a system received 200 and an empty bundle -- the server
      # reporting "no such patient" about a lookup it never performed.
      #
      # `index` applies the organization filter to this result set exactly as it
      # does to every other, so widening the match cannot cross a credential's
      # organization binding.
      def bare_identifier_search(value)
        found = []
        # A DFN is a positive integer. Guard on that rather than letting
        # String#to_i coerce an SSN such as "111-11-1111" into DFN 111.
        found << Patient.find_by_dfn(value) if value.to_s.match?(/\A\d+\z/)
        found.concat(Array(Patient.search_by_mrn(value)))
        found.concat(Array(Patient.search_by_ssn(value)))
        found.compact.uniq { |patient| patient.dfn.to_s }
      end

      # "system|value" per FHIR token search. A trailing "|" means an explicitly
      # empty system, which is not the same as no system at all.
      def split_identifier(token)
        return [ nil, token.to_s ] unless token.to_s.include?("|")

        system, value = token.to_s.split("|", 2)
        [ system.presence, value.to_s ]
      end

      def extract_ssn_from_identifier(identifier)
        # Accept system|value format (e.g. http://hl7.org/fhir/sid/us-ssn|111-11-1111)
        parts = identifier.split("|")
        parts.length == 2 ? parts[1] : identifier
      end

      def filter_by_birthdate(patients)
        target = Date.parse(params[:birthdate]) rescue nil
        return patients unless target

        patients.select { |p| p.dob == target }
      end

      def filter_by_gender(patients)
        sex_code = case params[:gender]
        when "male" then "M"
        when "female" then "F"
        else nil
        end
        return patients unless sex_code

        patients.select { |p| p.sex == sex_code }
      end

      def build_patient_entry(patient)
        { resource: patient.to_fhir, search: { mode: "match" } }
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
