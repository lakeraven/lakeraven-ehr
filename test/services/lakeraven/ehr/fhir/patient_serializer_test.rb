# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class PatientSerializerTest < ActiveSupport::TestCase
        # =============================================================================
        # CORE FHIR STRUCTURE
        # =============================================================================

        test "to_h returns Patient resourceType" do
          result = serialize(build_patient)

          assert_equal "Patient", result[:resourceType]
        end

        test "to_h includes patient DFN as id" do
          result = serialize(build_patient(dfn: 123))

          assert_equal "123", result[:id]
        end

        test "to_h includes US Core profile in meta" do
          result = serialize(build_patient)

          assert result[:meta][:profile].any? { |p| p.include?("us-core-patient") }
        end

        # =============================================================================
        # NAME
        # =============================================================================

        test "serializes name from VistA format" do
          result = serialize(build_patient(name: "SMITH,JOHN Q"))

          name = result[:name].first
          assert_equal "SMITH", name[:family]
          assert_includes name[:given], "JOHN"
        end

        test "handles name with no given name" do
          result = serialize(build_patient(name: "SMITH"))

          name = result[:name].first
          assert_equal "SMITH", name[:family]
        end

        # =============================================================================
        # GENDER
        # =============================================================================

        test "maps sex M to male" do
          result = serialize(build_patient(sex: "M"))
          assert_equal "male", result[:gender]
        end

        test "maps sex F to female" do
          result = serialize(build_patient(sex: "F"))
          assert_equal "female", result[:gender]
        end

        test "maps sex U to unknown" do
          result = serialize(build_patient(sex: "U"))
          assert_equal "unknown", result[:gender]
        end

        # =============================================================================
        # BIRTH DATE
        # =============================================================================

        test "includes birthDate as ISO 8601" do
          result = serialize(build_patient(dob: Date.new(1980, 5, 15)))

          assert_equal "1980-05-15", result[:birthDate]
        end

        test "omits birthDate when nil" do
          result = serialize(build_patient(dob: nil))

          assert_nil result[:birthDate]
        end

        # =============================================================================
        # IDENTIFIERS
        # =============================================================================

        test "includes DFN identifier with VA OID" do
          result = serialize(build_patient(dfn: 123))

          dfn_id = result[:identifier].find { |i| i[:system]&.include?("2.16.840.1.113883.4.349") }
          refute_nil dfn_id
          assert_equal "123", dfn_id[:value]
        end

        test "includes SSN identifier when present" do
          result = serialize(build_patient(ssn: "111-22-3333"))

          ssn_id = result[:identifier].find { |i| i[:system]&.include?("us-ssn") }
          refute_nil ssn_id
          assert_equal "111-22-3333", ssn_id[:value]
        end

        test "omits SSN identifier when blank" do
          result = serialize(build_patient(ssn: nil))

          ssn_ids = result[:identifier].select { |i| i[:system]&.include?("us-ssn") }
          assert_empty ssn_ids
        end

        # =============================================================================
        # ADDRESS
        # =============================================================================

        test "includes address when present" do
          result = serialize(build_patient(address_line1: "123 Main St", city: "Anchorage", state: "AK", zip_code: "99501"))

          addr = result[:address]&.first
          refute_nil addr
          assert_includes addr[:line], "123 Main St"
          assert_equal "Anchorage", addr[:city]
        end

        test "omits address when blank" do
          result = serialize(build_patient(address_line1: nil))

          assert_empty(result[:address] || [])
        end

        # =============================================================================
        # TELECOM
        # =============================================================================

        test "includes phone when present" do
          result = serialize(build_patient(phone: "907-555-1234"))

          telecom = result[:telecom]&.first
          refute_nil telecom
          assert_equal "phone", telecom[:system]
          assert_equal "907-555-1234", telecom[:value]
        end

        # =============================================================================
        # RACE EXTENSION (US Core)
        # =============================================================================

        test "includes US Core race extension with ombCategory for known race" do
          result = serialize(build_patient(race: "AMERICAN INDIAN"))

          race_ext = result[:extension].find { |e| e[:url]&.include?("us-core-race") }
          refute_nil race_ext

          omb = race_ext[:extension].find { |e| e[:url] == "ombCategory" }
          refute_nil omb
          assert_equal "1002-5", omb[:valueCoding][:code]
        end

        test "includes US Core race text for unknown race value" do
          result = serialize(build_patient(race: "CUSTOM RACE"))

          race_ext = result[:extension].find { |e| e[:url]&.include?("us-core-race") }
          refute_nil race_ext

          text = race_ext[:extension].find { |e| e[:url] == "text" }
          refute_nil text
          assert_equal "CUSTOM RACE", text[:valueString]
        end

        test "includes US Core ethnicity extension" do
          result = serialize(build_patient)

          eth_ext = result[:extension].find { |e| e[:url]&.include?("us-core-ethnicity") }
          refute_nil eth_ext
        end

        # =============================================================================
        # TRIBAL EXTENSIONS
        # =============================================================================

        test "includes tribal enrollment extension when present" do
          result = serialize(build_patient(tribal_enrollment_number: "ANLC-12345"))

          tribal_ext = result[:extension].find { |e| e[:url]&.include?("tribal") }
          refute_nil tribal_ext
          assert_equal "ANLC-12345", tribal_ext[:valueString]
        end

        test "omits tribal extension when enrollment blank" do
          result = serialize(build_patient(tribal_enrollment_number: nil))

          tribal_exts = (result[:extension] || []).select { |e| e[:url]&.include?("tribal-affiliation") }
          assert_empty tribal_exts
        end

        # =============================================================================
        # SOGI EXTENSIONS
        # =============================================================================

        test "includes sexual orientation extension when present" do
          result = serialize(build_patient(sexual_orientation: "Heterosexual"))

          so_ext = result[:extension].find { |e| e[:url]&.include?("sexualOrientation") }
          refute_nil so_ext
          assert_equal "Heterosexual", so_ext[:valueString]
        end

        test "includes gender identity extension when present" do
          result = serialize(build_patient(gender_identity: "Male"))

          gi_ext = result[:extension].find { |e| e[:url]&.include?("genderIdentity") }
          refute_nil gi_ext
          assert_equal "Male", gi_ext[:valueString]
        end

        test "omits SOGI extensions when blank" do
          result = serialize(build_patient(sexual_orientation: nil, gender_identity: nil))

          sogi_exts = (result[:extension] || []).select { |e|
            e[:url]&.include?("sexualOrientation") || e[:url]&.include?("genderIdentity")
          }
          assert_empty sogi_exts
        end

        # =============================================================================
        # EDGE CASES
        # =============================================================================

        test "handles missing optional fields" do
          patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
          result = serialize(patient)

          assert_equal "Patient", result[:resourceType]
          assert_nil result[:birthDate]
        end

        # =============================================================================
        # REDACTION POLICY INTEGRATION
        # =============================================================================

        test "research view redacts name via policy" do
          patient = build_patient
          policy = RedactionPolicy.new(view: :research)
          result = PatientSerializer.new(patient).to_h
          redacted = policy.apply(result)

          assert_empty(redacted[:name] || [])
        end

        test "external view removes SSN via policy" do
          patient = build_patient(ssn: "111-22-3333")
          policy = RedactionPolicy.new(view: :external)
          result = PatientSerializer.new(patient).to_h
          redacted = policy.apply(result)

          ssn_ids = (redacted[:identifier] || []).select { |i| i[:system]&.include?("ssn") }
          assert_empty ssn_ids
        end

        test "patient_safe view masks SSN via policy" do
          patient = build_patient(ssn: "111-22-3333")
          policy = RedactionPolicy.new(view: :patient_safe)
          result = PatientSerializer.new(patient).to_h
          redacted = policy.apply(result)

          ssn_id = (redacted[:identifier] || []).find { |i| i[:system]&.include?("ssn") }
          assert_includes ssn_id[:value], "***" if ssn_id
        end

        private

        def build_patient(attrs = {})
          defaults = {
            dfn: 1, name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15),
            race: "AMERICAN INDIAN", ssn: "111-22-3333",
            address_line1: "123 Main St", city: "Anchorage", state: "AK", zip_code: "99501",
            phone: "907-555-1234"
          }
          Patient.new(defaults.merge(attrs))
        end

        def serialize(patient)
          PatientSerializer.new(patient).to_h
        end
      end
    end
  end
end
