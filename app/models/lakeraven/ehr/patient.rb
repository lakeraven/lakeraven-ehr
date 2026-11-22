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

      # IHS single-letter race code (e.g. "I" = American Indian/Alaska
      # Native) and the patient's site IEN. No RPC fills them: ORWPT ID INFO
      # was read as carrying them, but its pieces 4 and 6 are the VETERAN
      # flag and the ward (rpms-rpc #309). A real source is #564; until then
      # only a caller that knows them (a partner fixture) sets them.
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

      # "01", "1", and " 1 " are one patient. PatientRepository#find resolves
      # with to_i, and SupplementalClinicalResources compares owners the same
      # way. A non-digit or non-positive value is not a dfn.
      def self.canonical_dfn(value)
        numeric = value.to_s.strip
        return nil unless numeric.match?(/\A\d+\z/)

        number = numeric.to_i
        number.positive? ? number.to_s : nil
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

      # Completed years from dob to date. A Feb 29 birth's anniversary is March 1
      # in a non-leap year. Nil when dob is blank or after the date.
      def age_on(date)
        born = dob&.to_date
        return nil unless born

        on = date.to_date
        return nil if born > on

        years = on.year - born.year
        years -= 1 if on < anniversary_in(born, on.year)
        years
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

        CapabilityGuard.ensure!(:tribal_enrollment)
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

      # The tribe for the US Core tribal-affiliation extension (#1187):
      # nil, or { name:, code:, enrolled: true|nil }. Once RPMS answers it is
      # authoritative (no tribe_ien → nil); if the read fails or returns nil,
      # the tribal_affiliation attribute is used with no code. `enrolled` is
      # true only when RPMS holds an enrollment number, never false, and the
      # number itself is never part of the result. Memoized, nil included.
      def fhir_tribal_affiliation
        return @fhir_tribal_affiliation if defined?(@fhir_tribal_affiliation)

        @fhir_tribal_affiliation = build_fhir_tribal_affiliation
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
        hash = hash.deep_stringify_keys
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

        # US Core tribal-affiliation (#1187): the tribe name from the
        # tribalAffiliation CodeableConcept. The extension carries no
        # enrollment number, so none is read from it.
        tribal_ext = Array(hash["extension"]).find { |e| e["url"].to_s.include?("tribal-affiliation") }
        if tribal_ext
          tribe_ext = Array(tribal_ext["extension"]).find { |e| e["url"] == "tribalAffiliation" }
          concept = tribe_ext && tribe_ext["valueCodeableConcept"]
          if concept
            attrs[:tribal_affiliation] = concept["text"].presence ||
                                         Array(concept["coding"]).first&.dig("display")
          end
        end

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

      def build_fhir_tribal_affiliation
        fallback = tribal_affiliation.presence && { name: tribal_affiliation, code: nil, enrolled: nil }
        return fallback unless dfn

        details = tribal_read { tribal_enrollment_details }
        return fallback if details.nil?

        ien = details[:tribe_ien]
        return nil if ien.blank?

        enrolled = details[:enrollment_number].present? || nil
        tribe = tribal_read { TribalEnrollmentGateway.tribe_info(ien) }
        if tribe.is_a?(Hash) && tribe[:name].present?
          { name: tribe[:name], code: tribe[:code].presence, enrolled: enrolled }
        elsif details[:tribe_name].present?
          { name: details[:tribe_name], code: nil, enrolled: enrolled }
        end
      end

      # A failed tribal read degrades to nil; the log names the error class
      # only, never the DFN or any tribe/enrollment value.
      def tribal_read
        yield
      rescue StandardError => e
        Rails.logger.warn("[tribal-affiliation] tribal read failed: #{e.class}")
        nil
      end

      def anniversary_in(born, year)
        return Date.new(year, 3, 1) if born.month == 2 && born.day == 29 && !Date.leap?(year)

        Date.new(year, born.month, born.day)
      end

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
