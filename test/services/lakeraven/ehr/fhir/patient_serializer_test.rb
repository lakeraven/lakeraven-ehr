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

        # US Core tribal affiliation (#1187). The serializer takes the tribe from
        # Patient#fhir_tribal_affiliation (nil, or { name:, code:, enrolled: })
        # and emits the us-core-tribal-affiliation complex extension. The
        # enrollment number is an identifier, not the tribe, and is never sent.

        test "includes US Core tribal affiliation extension for an enrolled patient" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))

          tribal_exts = tribal_extensions(result)
          assert_equal 1, tribal_exts.size
          assert_equal US_CORE_TRIBAL_URL, tribal_exts.first[:url]
        end

        test "tribal affiliation extension matches the US Core complex shape exactly" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))

          expected = {
            url: US_CORE_TRIBAL_URL,
            extension: [
              { url: "tribalAffiliation",
                valueCodeableConcept: {
                  coding: [ { system: IHS_TRIBE_SYSTEM, code: "901" } ],
                  text: "SYNTHETIC TRIBE A"
                } },
              { url: "isEnrolled", valueBoolean: true }
            ]
          }
          actual = tribal_extensions(result).first
          refute_nil actual
          # A display on the coding is not pinned either way.
          actual = actual.deep_dup
          Array(actual.dig(:extension, 0, :valueCodeableConcept, :coding)).each { |c| c.delete(:display) }
          assert_equal expected, actual
        end

        test "tribalAffiliation CodeableConcept carries the tribe name as text" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))

          concept = tribal_concept(result)
          refute_nil concept
          assert_equal "SYNTHETIC TRIBE A", concept[:text]
        end

        test "tribalAffiliation CodeableConcept carries the IHS tribe code under the lakeraven ihs-tribe system" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))

          concept = tribal_concept(result)
          refute_nil concept
          assert_equal 1, concept[:coding].size
          coding = concept[:coding].first
          assert_equal "901", coding[:code]
          assert_equal IHS_TRIBE_SYSTEM, coding[:system]
        end

        test "tribal affiliation extension has isEnrolled true for an enrolled patient" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))

          tribal_ext = tribal_extensions(result).first
          refute_nil tribal_ext
          enrolled = tribal_ext[:extension].select { |e| e[:url] == "isEnrolled" }
          assert_equal 1, enrolled.size
          assert_equal true, enrolled.first[:valueBoolean]
        end

        test "no serialized extension carries the enrollment number" do
          patient = tribal_patient({ name: "SYNTHETIC TRIBE A", code: "901", enrolled: true },
                                   tribal_enrollment_number: "SYN-0001")
          result = serialize(patient)

          refute_empty tribal_extensions(result)
          leaked = deep_values(result[:extension]).select { |v| v.to_s.include?("SYN-0001") }
          assert_empty leaked
        end

        test "tribal affiliation extension has no valueString" do
          patient = tribal_patient({ name: "SYNTHETIC TRIBE A", code: "901", enrolled: true },
                                   tribal_enrollment_number: "SYN-0001")
          result = serialize(patient)

          tribal_ext = tribal_extensions(result).first
          refute_nil tribal_ext
          refute_includes deep_keys(tribal_ext).map(&:to_s), "valueString"
        end

        test "tribal affiliation extension never carries a v3-TribalEntityUS coding" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))

          refute_empty tribal_extensions(result)
          v3 = deep_values(tribal_extensions(result)).select { |v| v.to_s.include?("v3-TribalEntityUS") }
          assert_empty v3
        end

        test "omits isEnrolled when enrollment is unknown" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: nil))

          tribal_ext = tribal_extensions(result).first
          refute_nil tribal_ext
          assert_equal [ "tribalAffiliation" ], tribal_ext[:extension].map { |e| e[:url] }
        end

        test "never sends isEnrolled false" do
          # The model contract never returns false; even so the serializer must
          # not turn anything other than true into an isEnrolled sub-extension.
          [ nil, false ].each do |not_enrolled|
            result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: not_enrolled))

            tribal_ext = tribal_extensions(result).first
            refute_nil tribal_ext, "enrolled #{not_enrolled.inspect}"
            assert_empty tribal_ext[:extension].select { |e| e[:url] == "isEnrolled" },
                         "enrolled #{not_enrolled.inspect}"
            refute_includes deep_values(tribal_ext), false
          end
        end

        test "tribal affiliation extension is present without isEnrolled when the enrollment read fails" do
          patient = build_patient(tribal_affiliation: "SYNTHETIC TRIBE A", tribal_enrollment_number: "SYN-0001")
          result = with_tribal_gateway(enrollment_details: ->(*) { raise StandardError, "synthetic broker failure" }) do
            serialize(patient)
          end

          tribal_ext = tribal_extensions(result).first
          refute_nil tribal_ext
          assert_equal US_CORE_TRIBAL_URL, tribal_ext[:url]
          assert_equal "SYNTHETIC TRIBE A", tribal_concept(result)[:text]
          assert_empty tribal_ext[:extension].select { |e| e[:url] == "isEnrolled" }
          assert_empty deep_values(result[:extension]).select { |v| v.to_s.include?("SYN-0001") }
        end

        test "serializes tribe and enrollment from the RPMS read end to end" do
          patient = build_patient(tribal_enrollment_number: "SYN-0001")
          result = with_tribal_gateway(
            enrollment_details: { enrollment_number: "SYN-0001", tribe_ien: 9001, tribe_name: "SYNTHETIC TRIBE A" },
            tribe_info: { ien: 9001, name: "SYNTHETIC TRIBE A", code: "901" }
          ) { serialize(patient) }

          tribal_ext = tribal_extensions(result).first
          refute_nil tribal_ext
          assert_equal US_CORE_TRIBAL_URL, tribal_ext[:url]
          concept = tribal_concept(result)
          assert_equal "SYNTHETIC TRIBE A", concept[:text]
          assert_equal [ "901" ], concept[:coding].map { |c| c[:code] }
          assert_equal [ IHS_TRIBE_SYSTEM ], concept[:coding].map { |c| c[:system] }
          assert_equal true, tribal_ext[:extension].find { |e| e[:url] == "isEnrolled" }&.dig(:valueBoolean)
          assert_empty deep_values(result[:extension]).select { |v| v.to_s.include?("SYN-0001") }
        end

        test "tribalAffiliation CodeableConcept has text only and no coding key when the tribe code is nil" do
          result = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: nil, enrolled: true))

          concept = tribal_concept(result)
          refute_nil concept
          assert_equal({ text: "SYNTHETIC TRIBE A" }, concept)
          refute concept.key?(:coding)
        end

        test "omits tribal affiliation extension when the patient has no tribe of membership" do
          # An enrollment number alone is not a tribe: nothing may be emitted.
          result = serialize(tribal_patient(nil, tribal_enrollment_number: "SYN-0001"))

          tribal_exts = (result[:extension] || []).select { |e| e[:url]&.include?("tribal-affiliation") }
          assert_empty tribal_exts
          assert_empty deep_values(result[:extension]).select { |v| v.to_s.include?("SYN-0001") }
        end

        test "omits tribal affiliation extension when RPMS names no tribe for the patient" do
          patient = build_patient(tribal_enrollment_number: "SYN-0001")
          result = with_tribal_gateway(
            enrollment_details: { enrollment_number: "SYN-0001", tribe_ien: nil, tribe_name: nil },
            tribe_info: nil
          ) { serialize(patient) }

          tribal_exts = (result[:extension] || []).select { |e| e[:url]&.include?("tribal-affiliation") }
          assert_empty tribal_exts
        end

        test "tribal affiliation round trips through from_fhir" do
          patient = tribal_patient({ name: "SYNTHETIC TRIBE A", code: "901", enrolled: true },
                                   tribal_enrollment_number: "SYN-0001")
          as_json = JSON.parse(serialize(patient).to_json)

          restored = Patient.from_fhir(as_json)

          assert_equal "SYNTHETIC TRIBE A", restored.tribal_affiliation
          assert_nil restored.tribal_enrollment_number
        end

        test "external and research views remove the serialized US Core tribal affiliation extension" do
          serialized = serialize(tribal_patient(name: "SYNTHETIC TRIBE A", code: "901", enrolled: true))
          assert_equal [ US_CORE_TRIBAL_URL ], tribal_extensions(serialized).map { |e| e[:url] }

          %i[external research].each do |view|
            redacted = RedactionPolicy.new(view: view).apply(serialized.deep_dup)

            assert_empty tribal_extensions(redacted), "#{view} view"
            assert_empty deep_values(redacted[:extension]).select { |v| v.to_s.include?("SYNTHETIC TRIBE A") },
                         "#{view} view"
          end
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

        US_CORE_TRIBAL_URL = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-tribal-affiliation"
        IHS_TRIBE_SYSTEM = "https://terminology.lakeraven.com/CodeSystem/ihs-tribe"

        # A patient whose #fhir_tribal_affiliation is pinned to `affiliation`
        # (nil = no tribe), so these tests do not depend on the RpmsRpc mock's
        # seeded tribal read for DFN 1.
        def tribal_patient(affiliation, attrs = {})
          patient = build_patient(attrs)
          patient.define_singleton_method(:fhir_tribal_affiliation) { affiliation }
          patient
        end

        # Non-destructively override TribalEnrollmentGateway class methods for
        # the block; a stub that responds to #call is invoked (so it can raise).
        def with_tribal_gateway(**stubs)
          gw = TribalEnrollmentGateway
          originals = stubs.keys.to_h { |name| [ name, gw.method(name) ] }
          stubs.each do |name, value|
            gw.define_singleton_method(name) { |*args| value.respond_to?(:call) ? value.call(*args) : value }
          end
          yield
        ensure
          originals&.each { |name, meth| gw.define_singleton_method(name, meth) }
        end

        def tribal_extensions(resource)
          (resource[:extension] || []).select { |e| e[:url]&.include?("tribal-affiliation") }
        end

        def tribal_concept(resource)
          sub = Array(tribal_extensions(resource).first&.dig(:extension)).find { |e| e[:url] == "tribalAffiliation" }
          sub && sub[:valueCodeableConcept]
        end

        # Every leaf value / every hash key anywhere inside a nested structure.
        def deep_values(node)
          case node
          when Hash then node.values.flat_map { |v| deep_values(v) }
          when Array then node.flat_map { |v| deep_values(v) }
          else [ node ]
          end
        end

        def deep_keys(node)
          case node
          when Hash then node.keys + node.values.flat_map { |v| deep_keys(v) }
          when Array then node.flat_map { |v| deep_keys(v) }
          else []
          end
        end
      end
    end
  end
end
