# frozen_string_literal: true

module Lakeraven
  module EHR
    # Patient model — ActiveModel-based, backed by RPMS via PatientGateway.
    #
    # Faithful port from the predecessor app Patient. All data flows through RPC;
    # no database tables.
    class Patient
      include ActiveModel::Model
      include ActiveModel::Attributes

      # RPMS/VistA core demographics
      attribute :dfn, :integer
      attribute :name, :string
      attribute :ssn, :string
      attribute :dob, :date
      attribute :sex, :string
      attribute :age, :integer
      attribute :race, :string
      attribute :address_line1, :string
      attribute :city, :string
      attribute :state, :string
      attribute :zip_code, :string
      attribute :phone, :string

      # Date aliases
      attribute :born_on, :date
      attribute :birth_date, :date

      # Derived name parts
      attribute :first_name, :string
      attribute :last_name, :string

      # IHS/PRC fields
      attribute :tribal_affiliation, :string
      attribute :tribal_enrollment_number, :string
      attribute :service_area, :string
      attribute :coverage_type, :string

      # From ORWPT ID INFO — IHS single-letter race code (e.g. "I" =
      # American Indian/Alaska Native) and the current site IEN. Distinct
      # from `:race` which holds the long-form string and currently isn't
      # populated by any RPC mapped to this codebase.
      attribute :race_code, :string
      attribute :site_ien, :integer

      # SOGI data elements (USCDI v3 / ONC 170.315(a)(15))
      attribute :sexual_orientation, :string
      attribute :gender_identity, :string

      class RecordNotFound < StandardError; end

      # Provenance — set by repository at hydration time
      attr_accessor :provenance

      # Validations
      validates :name, presence: true, if: -> { first_name.blank? && last_name.blank? }
      validates :sex, inclusion: { in: %w[M F U], allow_nil: true }

      # -- Public API (delegates to repository) --------------------------------

      def self.find(dfn)
        patient = PatientRepository.find(dfn)
        raise RecordNotFound, "Couldn't find Patient with 'dfn'=#{dfn}" unless patient

        patient
      end

      def self.find_by_dfn(dfn)
        PatientRepository.find(dfn)
      end

      def self.search(name_pattern)
        PatientRepository.search(name_pattern.to_s)
      end

      def self.search_by_ssn(ssn)
        patient = find_by_ssn(ssn)
        patient ? [ patient ] : []
      end

      def self.find_by_ssn(ssn)
        PatientRepository.find_by_ssn(ssn)
      end

      # -- Write operations (remain on gateway for now) ------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || PatientGateway
        end
      end

      def save
        return false unless valid?

        if persisted?
          true
        else
          result = self.class.gateway.register(persistable_attributes)
          if result[:success]
            self.dfn = result[:dfn]
            true
          else
            errors.add(:base, result[:error] || "Registration failed")
            false
          end
        end
      end

      def save!
        save || raise(ActiveModel::ValidationError.new(self))
      end

      def self.create(attributes = {})
        new(attributes).tap(&:save)
      end

      def self.create!(attributes = {})
        new(attributes).tap(&:save!)
      end

      # -- Initialize with composite field sync ------------------------------

      def initialize(attributes = {})
        super
        sync_composite_fields
      end

      # -- Name helpers ------------------------------------------------------

      def display_name
        return name if name.blank?

        parts = name.split(",")
        last = parts[0]&.strip
        first = parts[1]&.strip
        first.present? ? "#{first} #{last}" : last
      end

      def formal_name
        return name if name.blank?

        parts = name.split(",")
        if parts.length >= 2
          last = parts[0]&.strip&.split&.map(&:capitalize)&.join(" ")
          first = parts[1]&.strip&.split&.map(&:capitalize)&.join(" ")
          "#{last}, #{first}"
        else
          name.split.map(&:capitalize).join(" ")
        end
      end

      def to_param
        dfn.to_s
      end

      def persisted?
        dfn.present? && dfn.to_i.positive?
      end

      # -- Clinical data accessors (ported from the predecessor app) ------------------

      def service_requests
        return [] unless dfn

        ServiceRequest.for_patient(dfn)
      end

      def allergies
        return [] unless dfn

        AllergyIntolerance.for_patient(dfn)
      end

      def problem_list
        return [] unless dfn

        Condition.for_patient(dfn)
      end

      def medications
        return [] unless dfn

        MedicationRequest.for_patient(dfn)
      end

      def vitals
        return [] unless dfn

        Observation.for_patient(dfn)
      end

      # -- Tribal enrollment -------------------------------------------------
      #
      # Migrated to rpms-rpc 0.3.0 (#235), which rebuilt RpmsRpc::Tribal on real
      # DDR FileMan reads over #9000001 / #9999999.03 / #9999999.22 and DELETED
      # the invented placeholder shapes. The removed placeholders fabricated
      # three things this code relied on: an ACTIVE/INACTIVE enrollment
      # "status", per-patient service-unit reads, and a tribe code encoded in
      # the enrollment number. None has an RPMS source, so none is reconstructed
      # here.
      #
      # ELIGIBILITY FAILS CLOSED. The new read returns an eligibility_status set
      # code (I/D/C/P); mapping those to an IHS-services eligibility
      # DETERMINATION is a compliance decision (OCAP / eligibility-determination
      # territory) tracked in #520 and out of Sprint 1 (BH-only) scope. Until it
      # is signed off, every status is treated as UNDETERMINED, and an
      # undetermined determination is NOT eligible — never "eligible" (the
      # SOFTWARE-FACTORY non-negotiable: absence of a determination may not
      # confer eligibility).

      def tribal_enrollment_details
        return nil unless dfn

        TribalEnrollmentGateway.enrollment_details(dfn)
      end

      def validate_tribal_enrollment
        return { valid: false, message: "No enrollment number" } if tribal_enrollment_number.blank?

        # 0.3.0 validate is a SYNTACTIC check of #9000001 field .07 (VAL^DIE via
        # DDR VALIDATOR) → { valid:, internal:, external: }. It no longer claims
        # tribe-membership or active-status validation; no such server check
        # exists.
        TribalEnrollmentGateway.validate(tribal_enrollment_number)
      end

      def tribal_enrollment_valid?
        result = validate_tribal_enrollment
        !!(result && result[:valid])
      end

      # Fail-closed eligibility. Returns the raw status for transparency but
      # never derives "eligible" from it until #520 maps the set codes.
      def tribal_enrollment_eligibility
        undetermined = { eligible: false, determination: :undetermined,
                         eligibility_status: nil, classification: nil }
        return undetermined unless persisted?

        read = TribalEnrollmentGateway.eligibility(dfn)
        return undetermined if read.nil?

        undetermined.merge(
          eligibility_status: read[:eligibility_status],
          classification: read[:classification]
        )
      end

      def eligible_for_ihs_services?
        tribal_enrollment_eligibility[:determination] == :eligible
      end

      # No per-patient service-unit read exists in 0.3.0 (it derives from
      # community linkage, not a patient-file field). Undetermined until that
      # path is built (#520).
      def enrollment_service_unit
        nil
      end

      # The tribe now comes from the enrollment's TRIBE-OF-MEMBERSHIP pointer
      # (#9000001 field 1108 → tribe IEN), read as a real #9999999.03 entry —
      # not by splitting a tribe code out of the enrollment number, which the
      # placeholder fabricated.
      def tribe_information
        details = tribal_enrollment_details
        ien = details && details[:tribe_ien]
        return nil if ien.blank?

        TribalEnrollmentGateway.tribe_info(ien)
      end

      # -- Providers (ported from the predecessor app) ----------------------------------

      def providers
        all_srs = service_requests || []
        provider_iens = (all_srs.map(&:requesting_provider_ien) +
                         all_srs.map { |sr| sr.respond_to?(:referred_provider_ien) ? sr.referred_provider_ien : nil })
                        .compact.uniq.select(&:positive?)
        provider_iens.filter_map { |ien| Practitioner.find_by_ien(ien) }
      end

      # -- FHIR serialization -----------------------------------------------

      def to_fhir
        FHIR::PatientSerializer.call(self)
      end

      # -- FHIR deserialization -----------------------------------------------

      def self.from_fhir(hash)
        hash = hash.transform_keys(&:to_s)
        name_entry = Array(hash["name"]).first || {}
        family = name_entry["family"].to_s
        given = Array(name_entry["given"]).join(" ")
        name = given.present? ? "#{family},#{given}" : family

        ssn = Array(hash["identifier"]).find { |i| i["system"].to_s.include?("us-ssn") }&.dig("value")

        attrs = {
          dfn: hash["id"].to_i,
          name: name,
          dob: hash["birthDate"] ? Date.parse(hash["birthDate"]) : nil,
          sex: case hash["gender"]
               when "male" then "M"
               when "female" then "F"
               else "U"
               end,
          ssn: ssn
        }

        addr = Array(hash["address"]).first
        if addr
          attrs[:address_line1] = Array(addr["line"]).first
          attrs[:city] = addr["city"]
          attrs[:state] = addr["state"]
          attrs[:zip_code] = addr["postalCode"]
        end

        phone = Array(hash["telecom"]).find { |t| t["system"] == "phone" }
        attrs[:phone] = phone["value"] if phone

        race_ext = Array(hash["extension"]).find { |e| e["url"].to_s.include?("us-core-race") }
        if race_ext
          text_ext = Array(race_ext["extension"]).find { |e| e["url"] == "text" }
          attrs[:race] = text_ext["valueString"] if text_ext
        end

        tribal_ext = Array(hash["extension"]).find { |e| e["url"].to_s.include?("tribal-affiliation") }
        attrs[:tribal_enrollment_number] = tribal_ext["valueString"] if tribal_ext

        new(**attrs.compact)
      end

      def self.from_fhir_attributes(fhir_resource)
        gender_code = map_fhir_gender_to_sex(fhir_resource.gender)
        {
          name: extract_name_from_fhir(fhir_resource),
          dob: fhir_resource.birthDate ? Date.parse(fhir_resource.birthDate) : nil,
          sex: gender_code,
          ssn: extract_ssn_from_fhir(fhir_resource)
        }
      end

      def self.extract_name_from_fhir(fhir_resource)
        return nil unless fhir_resource.name&.any?
        name_obj = fhir_resource.name.first
        return name_obj.text if name_obj.respond_to?(:text) && name_obj.text.present?
        family = name_obj.family
        given = name_obj.given&.join(" ")
        given.present? ? "#{family},#{given}" : family
      end

      def self.map_fhir_gender_to_sex(gender)
        case gender&.downcase
        when "male" then "M"
        when "female" then "F"
        else "U"
        end
      end

      def self.extract_ssn_from_fhir(fhir_resource)
        return nil unless fhir_resource.identifier&.any?
        ssn_id = fhir_resource.identifier.find { |id| id.system&.include?("ssn") }
        ssn_id&.value
      end

      private

      def persistable_attributes
        {
          name: name, first_name: first_name, last_name: last_name,
          dob: dob, born_on: born_on, sex: sex, ssn: ssn,
          address_line1: address_line1, city: city, state: state,
          zip_code: zip_code, phone: phone, race: race,
          tribal_enrollment_number: tribal_enrollment_number,
          service_area: service_area, coverage_type: coverage_type
        }.compact
      end

      def sync_composite_fields
        # Sync born_on ↔ dob
        self.born_on ||= dob
        self.dob ||= born_on

        # Sync name ↔ first_name/last_name
        self.name = "#{last_name},#{first_name}" if first_name.present? && last_name.present? && name.blank?

        return unless name.present? && first_name.blank? && last_name.blank?

        parts = name.split(",")
        self.last_name = parts[0]&.strip&.capitalize
        self.first_name = parts[1]&.strip&.capitalize if parts.length > 1
      end
    end
  end
end
