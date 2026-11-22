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

        # US Core race extension: ombCategory value set (#1186)
        CDC_RACE_SYSTEM = "urn:oid:2.16.840.1.113883.6.238"
        NULL_FLAVOR_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-NullFlavor"
        OMB_RACE_CODES = %w[1002-5 2028-9 2054-5 2076-8 2106-3].freeze
        NULL_FLAVOR_RACE_CODES = %w[UNK ASKU].freeze

        OMB_CATEGORY_ROWS = [
          { rpms: "AMERICAN INDIAN OR ALASKA NATIVE", omb: "1002-5", system: CDC_RACE_SYSTEM,
            text: "American Indian or Alaska Native" },
          { rpms: "WHITE", omb: "2106-3", system: CDC_RACE_SYSTEM, text: "White" },
          { rpms: "UNKNOWN", omb: "UNK", system: NULL_FLAVOR_SYSTEM, text: "Unknown" },
          { rpms: "DECLINED TO ANSWER", omb: "ASKU", system: NULL_FLAVOR_SYSTEM, text: "Declined to answer" }
        ].freeze

        TEXT_ONLY_RACES = [ "OTHER", "CUSTOM RACE" ].freeze

        OMB_CATEGORY_ROWS.each do |row|
          test "race #{row[:rpms]} serializes ombCategory #{row[:omb]} from #{row[:system]}" do
            race_ext = race_extension(serialize(build_patient(race: row[:rpms])))
            refute_nil race_ext

            ombs = omb_categories(race_ext)
            assert_equal 1, ombs.size, "Expected exactly one ombCategory for '#{row[:rpms]}'"
            coding = ombs.first[:valueCoding]
            assert_equal row[:omb], coding[:code]
            assert_equal row[:system], coding[:system]

            assert_equal [ row[:text] ], race_texts(race_ext)
          end
        end

        TEXT_ONLY_RACES.each do |race|
          test "race #{race} serializes as text only with no ombCategory" do
            race_ext = race_extension(serialize(build_patient(race: race)))
            refute_nil race_ext

            assert_empty omb_categories(race_ext), "Expected no ombCategory for '#{race}'"
            assert_equal [ race ], race_texts(race_ext)
          end
        end

        test "every RACE_CODE_MAP key serializes an ombCategory allowed by US Core" do
          PatientSerializer::RACE_CODE_MAP.each_key do |race|
            race_ext = race_extension(serialize(build_patient(race: race)))
            refute_nil race_ext, "Expected race extension for '#{race}'"

            omb_categories(race_ext).each do |omb|
              coding = omb[:valueCoding]
              refute_equal "2131-1", coding[:code], "'#{race}' must not emit 2131-1 under ombCategory"

              omb_code = coding[:system] == CDC_RACE_SYSTEM && OMB_RACE_CODES.include?(coding[:code])
              null_flavor = coding[:system] == NULL_FLAVOR_SYSTEM && NULL_FLAVOR_RACE_CODES.include?(coding[:code])
              assert omb_code || null_flavor,
                "'#{race}' emitted ombCategory #{coding[:system]}|#{coding[:code]}, not in the US Core value set"
            end
          end
        end

        test "no serialized race emits code 2131-1" do
          races = PatientSerializer::RACE_CODE_MAP.keys + OMB_CATEGORY_ROWS.map { |r| r[:rpms] } + TEXT_ONLY_RACES

          races.uniq.each do |race|
            result = serialize(build_patient(race: race))
            refute_includes result.to_json, "2131-1", "'#{race}' output must not contain 2131-1"
          end
        end

        test "every race extension has exactly one non-empty text" do
          races = PatientSerializer::RACE_CODE_MAP.keys + OMB_CATEGORY_ROWS.map { |r| r[:rpms] } + TEXT_ONLY_RACES

          races.uniq.each do |race|
            race_ext = race_extension(serialize(build_patient(race: race)))
            refute_nil race_ext, "Expected race extension for '#{race}'"

            texts = race_texts(race_ext)
            assert_equal 1, texts.size, "Expected exactly one text for '#{race}'"
            assert texts.first.present?, "Expected non-empty text for '#{race}'"
          end
        end

        test "race UNKNOWN uses the v3-NullFlavor display unknown" do
          race_ext = race_extension(serialize(build_patient(race: "UNKNOWN")))
          coding = omb_categories(race_ext).first&.dig(:valueCoding)

          refute_nil coding
          assert_equal NULL_FLAVOR_SYSTEM, coding[:system]
          assert_equal "unknown", coding[:display]
        end

        test "race DECLINED TO ANSWER uses the v3-NullFlavor display asked but unknown" do
          race_ext = race_extension(serialize(build_patient(race: "DECLINED TO ANSWER")))
          coding = omb_categories(race_ext).first&.dig(:valueCoding)

          refute_nil coding
          assert_equal NULL_FLAVOR_SYSTEM, coding[:system]
          assert_equal "asked but unknown", coding[:display]
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
          result = serialize(build_patient(tribal_enrollment_number: "EXNH-12345"))

          tribal_ext = result[:extension].find { |e| e[:url]&.include?("tribal") }
          refute_nil tribal_ext
          assert_equal "EXNH-12345", tribal_ext[:valueString]
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

        def race_extension(result)
          (result[:extension] || []).find { |e| e[:url]&.include?("us-core-race") }
        end

        def omb_categories(race_ext)
          race_ext[:extension].select { |e| e[:url] == "ombCategory" }
        end

        def race_texts(race_ext)
          race_ext[:extension].select { |e| e[:url] == "text" }.map { |e| e[:valueString] }
        end
      end
    end
  end
end
