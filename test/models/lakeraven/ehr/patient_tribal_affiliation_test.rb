# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #1187 — US Core tribal affiliation.
    #
    # Patient#fhir_tribal_affiliation is the single source the FHIR serializer
    # uses for the us-core-tribal-affiliation extension. It returns nil (no
    # tribe) or { name: String, code: String|nil, enrolled: true|nil }.
    # `enrolled` is true only when RPMS holds an enrollment; it is never false
    # (unknown is nil). The enrollment number itself is never part of the result.
    #
    # Patient.from_fhir reads the complex extension back into
    # `tribal_affiliation` and no longer reads an enrollment number from it.
    class PatientTribalAffiliationTest < ActiveSupport::TestCase
      TRIBE_NAME = "SYNTHETIC TRIBE A"
      TRIBE_CODE = "901"
      TRIBE_IEN = 9001
      ENROLLMENT_NUMBER = "SYN-0001"
      US_CORE_TRIBAL_URL = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-tribal-affiliation"
      IHS_TRIBE_SYSTEM = "https://terminology.lakeraven.com/CodeSystem/ihs-tribe"

      # Non-destructively override TribalEnrollmentGateway class methods for the
      # block (same approach as PatientTribalEnrollmentTest#with_gateway). A
      # stub value that responds to #call is invoked with the gateway arguments,
      # so a stub can raise or count calls; anything else is returned as-is.
      def with_gateway(**stubs)
        gw = TribalEnrollmentGateway
        originals = stubs.keys.to_h { |name| [ name, gw.method(name) ] }
        stubs.each do |name, value|
          gw.define_singleton_method(name) { |*args| value.respond_to?(:call) ? value.call(*args) : value }
        end
        yield
      ensure
        originals&.each { |name, meth| gw.define_singleton_method(name, meth) }
      end

      def enrollment_read(overrides = {})
        { enrollment_number: ENROLLMENT_NUMBER, tribe_ien: TRIBE_IEN, tribe_name: TRIBE_NAME }.merge(overrides)
      end

      def tribe_entry
        { ien: TRIBE_IEN, name: TRIBE_NAME, code: TRIBE_CODE }
      end

      def patient(attrs = {})
        Patient.new({ dfn: 4242, name: "SYNTHETIC,PATIENT" }.merge(attrs))
      end

      def complex_extension(concept)
        {
          "url" => US_CORE_TRIBAL_URL,
          "extension" => [
            { "url" => "tribalAffiliation", "valueCodeableConcept" => concept },
            { "url" => "isEnrolled", "valueBoolean" => true }
          ]
        }
      end

      def fhir_patient(*extensions)
        {
          "resourceType" => "Patient", "id" => "4242",
          "name" => [ { "family" => "SYNTHETIC", "given" => [ "PATIENT" ] } ],
          "gender" => "unknown",
          "extension" => extensions
        }
      end

      # -- fhir_tribal_affiliation: RPMS answered with a tribe ----------------

      test "fhir_tribal_affiliation returns tribe name, IHS code and enrolled true for an enrolled patient" do
        with_gateway(enrollment_details: enrollment_read, tribe_info: tribe_entry) do
          assert_equal({ name: TRIBE_NAME, code: TRIBE_CODE, enrolled: true },
                       patient.fhir_tribal_affiliation)
        end
      end

      test "fhir_tribal_affiliation takes name and code from the TRIBE entry, not the enrollment pointer text" do
        with_gateway(enrollment_details: enrollment_read(tribe_name: "SYNTHETIC POINTER TEXT"),
                     tribe_info: tribe_entry) do
          result = patient.fhir_tribal_affiliation
          assert_equal TRIBE_NAME, result[:name]
          assert_equal TRIBE_CODE, result[:code]
        end
      end

      test "fhir_tribal_affiliation looks the tribe up by the enrollment's tribe_ien" do
        seen = []
        with_gateway(enrollment_details: enrollment_read,
                     tribe_info: ->(ien) { seen << ien; tribe_entry }) do
          patient.fhir_tribal_affiliation
        end
        assert_equal [ TRIBE_IEN ], seen
      end

      test "fhir_tribal_affiliation never exposes the enrollment number" do
        with_gateway(enrollment_details: enrollment_read, tribe_info: tribe_entry) do
          result = patient(tribal_enrollment_number: ENROLLMENT_NUMBER).fhir_tribal_affiliation
          assert_equal %i[code enrolled name], result.keys.sort
          refute_includes result.values, ENROLLMENT_NUMBER
        end
      end

      test "fhir_tribal_affiliation has enrolled nil, never false, when the enrollment number is blank" do
        [ nil, "" ].each do |blank|
          with_gateway(enrollment_details: enrollment_read(enrollment_number: blank), tribe_info: tribe_entry) do
            result = patient.fhir_tribal_affiliation
            assert_equal({ name: TRIBE_NAME, code: TRIBE_CODE, enrolled: nil }, result,
                         "enrollment_number #{blank.inspect}")
            assert_nil result[:enrolled]
          end
        end
      end

      test "fhir_tribal_affiliation falls back to the read's tribe_name with no code when tribe_info returns nil" do
        with_gateway(enrollment_details: enrollment_read, tribe_info: nil) do
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: true },
                       patient.fhir_tribal_affiliation)
        end
      end

      test "fhir_tribal_affiliation falls back to the read's tribe_name with no code when tribe_info raises" do
        with_gateway(enrollment_details: enrollment_read,
                     tribe_info: ->(*) { raise StandardError, "synthetic broker failure" }) do
          result = nil
          assert_nothing_raised { result = patient.fhir_tribal_affiliation }
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: true }, result)
        end
      end

      test "fhir_tribal_affiliation keeps enrolled nil in the tribe_info fallback when the enrollment number is blank" do
        with_gateway(enrollment_details: enrollment_read(enrollment_number: nil), tribe_info: nil) do
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: nil },
                       patient.fhir_tribal_affiliation)
        end
      end

      # -- fhir_tribal_affiliation: RPMS answered, no tribe -------------------

      test "fhir_tribal_affiliation is nil when the read names no tribe" do
        [ nil, "" ].each do |blank|
          with_gateway(enrollment_details: enrollment_read(tribe_ien: blank, tribe_name: nil), tribe_info: nil) do
            assert_nil patient.fhir_tribal_affiliation, "tribe_ien #{blank.inspect}"
          end
        end
      end

      test "fhir_tribal_affiliation is nil when the read names no tribe even if the attribute is set" do
        with_gateway(enrollment_details: enrollment_read(tribe_ien: nil, tribe_name: nil), tribe_info: nil) do
          assert_nil patient(tribal_affiliation: TRIBE_NAME).fhir_tribal_affiliation
        end
      end

      # -- fhir_tribal_affiliation: RPMS did not answer -----------------------

      test "fhir_tribal_affiliation falls back to the tribal_affiliation attribute when the read returns nil" do
        with_gateway(enrollment_details: nil) do
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: nil },
                       patient(tribal_affiliation: TRIBE_NAME).fhir_tribal_affiliation)
        end
      end

      test "fhir_tribal_affiliation is nil when the read returns nil and no attribute is set" do
        with_gateway(enrollment_details: nil) do
          assert_nil patient.fhir_tribal_affiliation
        end
      end

      test "fhir_tribal_affiliation falls back to the attribute when the read raises" do
        with_gateway(enrollment_details: ->(*) { raise StandardError, "synthetic broker failure" }) do
          result = nil
          assert_nothing_raised { result = patient(tribal_affiliation: TRIBE_NAME).fhir_tribal_affiliation }
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: nil }, result)
        end
      end

      test "fhir_tribal_affiliation falls back to the attribute when the capability is unavailable" do
        unavailable = ->(*) { raise FeatureUnavailable.new(:tribal_enrollment) }
        with_gateway(enrollment_details: unavailable) do
          result = nil
          assert_nothing_raised { result = patient(tribal_affiliation: TRIBE_NAME).fhir_tribal_affiliation }
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: nil }, result)
        end
      end

      test "fhir_tribal_affiliation is nil and does not raise when the read raises and no attribute is set" do
        with_gateway(enrollment_details: ->(*) { raise StandardError, "synthetic broker failure" }) do
          result = :unset
          assert_nothing_raised { result = patient.fhir_tribal_affiliation }
          assert_nil result
        end
      end

      test "fhir_tribal_affiliation does not claim enrollment from the attribute fallback" do
        with_gateway(enrollment_details: nil) do
          result = patient(tribal_affiliation: TRIBE_NAME,
                           tribal_enrollment_number: ENROLLMENT_NUMBER).fhir_tribal_affiliation
          assert_nil result[:enrolled]
          assert_nil result[:code]
        end
      end

      # -- fhir_tribal_affiliation: no dfn ------------------------------------

      test "fhir_tribal_affiliation uses the attribute without a gateway call for a patient with no dfn" do
        calls = 0
        counting = ->(*) { calls += 1; enrollment_read }
        with_gateway(enrollment_details: counting, tribe_info: ->(*) { calls += 1; tribe_entry }) do
          result = Patient.new(name: "SYNTHETIC,PATIENT", tribal_affiliation: TRIBE_NAME).fhir_tribal_affiliation
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: nil }, result)
        end
        assert_equal 0, calls
      end

      test "fhir_tribal_affiliation is nil for a patient with no dfn and no attribute" do
        calls = 0
        with_gateway(enrollment_details: ->(*) { calls += 1; enrollment_read }) do
          assert_nil Patient.new(name: "SYNTHETIC,PATIENT").fhir_tribal_affiliation
        end
        assert_equal 0, calls
      end

      # -- fhir_tribal_affiliation: memoization -------------------------------

      test "fhir_tribal_affiliation is memoized so two calls make one enrollment read" do
        reads = 0
        with_gateway(enrollment_details: ->(*) { reads += 1; enrollment_read }, tribe_info: tribe_entry) do
          subject = patient
          first = subject.fhir_tribal_affiliation
          second = subject.fhir_tribal_affiliation
          assert_equal({ name: TRIBE_NAME, code: TRIBE_CODE, enrolled: true }, first)
          assert_equal first, second
        end
        assert_equal 1, reads
      end

      test "fhir_tribal_affiliation memoizes a nil result too" do
        reads = 0
        with_gateway(enrollment_details: ->(*) { reads += 1; nil }) do
          subject = patient
          assert_nil subject.fhir_tribal_affiliation
          assert_nil subject.fhir_tribal_affiliation
        end
        assert_equal 1, reads
      end

      # -- fhir_tribal_affiliation: robustness (#1187 round 2) -----------------

      test "fhir_tribal_affiliation treats a non-Hash enrollment read as a failed read and falls back to the attribute" do
        [ "SYNTHETIC GARBAGE", [ "SYNTHETIC GARBAGE" ], 42, true ].each do |garbage|
          with_gateway(enrollment_details: garbage, tribe_info: tribe_entry) do
            result = :unset
            assert_nothing_raised { result = patient(tribal_affiliation: TRIBE_NAME).fhir_tribal_affiliation }
            assert_equal({ name: TRIBE_NAME, code: nil, enrolled: nil }, result, "read #{garbage.inspect}")
          end
        end
      end

      test "fhir_tribal_affiliation is nil for a non-Hash enrollment read when no attribute is set" do
        [ "SYNTHETIC GARBAGE", [ "SYNTHETIC GARBAGE" ], 42, true ].each do |garbage|
          with_gateway(enrollment_details: garbage, tribe_info: tribe_entry) do
            result = :unset
            assert_nothing_raised { result = patient.fhir_tribal_affiliation }
            assert_nil result, "read #{garbage.inspect}"
          end
        end
      end

      test "fhir_tribal_affiliation strips whitespace around the tribe name and code" do
        with_gateway(enrollment_details: enrollment_read,
                     tribe_info: { ien: TRIBE_IEN, name: "  #{TRIBE_NAME} \n", code: " #{TRIBE_CODE}  " }) do
          assert_equal({ name: TRIBE_NAME, code: TRIBE_CODE, enrolled: true },
                       patient.fhir_tribal_affiliation)
        end
      end

      test "fhir_tribal_affiliation returns an Integer tribe code as a String" do
        with_gateway(enrollment_details: enrollment_read,
                     tribe_info: { ien: TRIBE_IEN, name: TRIBE_NAME, code: 901 }) do
          result = patient.fhir_tribal_affiliation
          assert_equal "901", result[:code]
          assert_instance_of String, result[:code]
        end
      end

      test "fhir_tribal_affiliation has a nil code when the tribe code is only whitespace" do
        with_gateway(enrollment_details: enrollment_read,
                     tribe_info: { ien: TRIBE_IEN, name: TRIBE_NAME, code: "   " }) do
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: true }, patient.fhir_tribal_affiliation)
        end
      end

      test "fhir_tribal_affiliation strips whitespace around the read's tribe_name in the tribe_info fallback" do
        with_gateway(enrollment_details: enrollment_read(tribe_name: " #{TRIBE_NAME}  "), tribe_info: nil) do
          assert_equal({ name: TRIBE_NAME, code: nil, enrolled: true }, patient.fhir_tribal_affiliation)
        end
      end

      test "fhir_tribal_affiliation memo is per dfn so a changed dfn re-reads" do
        other_dfn = 4343
        reads = []
        by_dfn = {
          4242 => enrollment_read,
          other_dfn => enrollment_read(enrollment_number: nil, tribe_ien: 9002, tribe_name: "SYNTHETIC TRIBE B")
        }
        tribes = { TRIBE_IEN => tribe_entry, 9002 => { ien: 9002, name: "SYNTHETIC TRIBE B", code: "902" } }
        with_gateway(enrollment_details: ->(dfn) { reads << dfn; by_dfn.fetch(dfn) },
                     tribe_info: ->(ien) { tribes.fetch(ien) }) do
          subject = patient
          assert_equal({ name: TRIBE_NAME, code: TRIBE_CODE, enrolled: true }, subject.fhir_tribal_affiliation)

          subject.dfn = other_dfn
          assert_equal({ name: "SYNTHETIC TRIBE B", code: "902", enrolled: nil }, subject.fhir_tribal_affiliation)
          subject.fhir_tribal_affiliation
        end
        assert_equal [ 4242, other_dfn ], reads
      end

      # -- Patient.from_fhir --------------------------------------------------

      test "from_fhir reads tribal_affiliation from the complex extension's CodeableConcept text" do
        concept = { "coding" => [ { "system" => IHS_TRIBE_SYSTEM, "code" => TRIBE_CODE } ], "text" => TRIBE_NAME }
        result = Patient.from_fhir(fhir_patient(complex_extension(concept)))

        assert_equal TRIBE_NAME, result.tribal_affiliation
      end

      test "from_fhir prefers the CodeableConcept text over a coding display" do
        concept = { "coding" => [ { "system" => IHS_TRIBE_SYSTEM, "code" => TRIBE_CODE,
                                    "display" => "SYNTHETIC DISPLAY B" } ],
                    "text" => TRIBE_NAME }
        result = Patient.from_fhir(fhir_patient(complex_extension(concept)))

        assert_equal TRIBE_NAME, result.tribal_affiliation
      end

      test "from_fhir reads tribal_affiliation from the first coding display when there is no text" do
        concept = { "coding" => [
          { "system" => IHS_TRIBE_SYSTEM, "code" => TRIBE_CODE, "display" => TRIBE_NAME },
          { "system" => IHS_TRIBE_SYSTEM, "code" => "902", "display" => "SYNTHETIC TRIBE B" }
        ] }
        result = Patient.from_fhir(fhir_patient(complex_extension(concept)))

        assert_equal TRIBE_NAME, result.tribal_affiliation
      end

      test "from_fhir leaves tribal_enrollment_number nil for the complex extension" do
        concept = { "coding" => [ { "system" => IHS_TRIBE_SYSTEM, "code" => TRIBE_CODE } ], "text" => TRIBE_NAME }
        result = Patient.from_fhir(fhir_patient(complex_extension(concept)))

        assert_equal TRIBE_NAME, result.tribal_affiliation
        assert_nil result.tribal_enrollment_number
      end

      test "from_fhir does not read an enrollment number from an old-shape valueString extension" do
        old_shape = { "url" => "http://hl7.org/fhir/us/core/StructureDefinition/tribal-affiliation",
                      "valueString" => ENROLLMENT_NUMBER }
        result = Patient.from_fhir(fhir_patient(old_shape))

        assert_nil result.tribal_enrollment_number
      end

      test "from_fhir does not read an enrollment number from a valueString on the new-URL extension" do
        stray = { "url" => US_CORE_TRIBAL_URL, "valueString" => ENROLLMENT_NUMBER }
        result = Patient.from_fhir(fhir_patient(stray))

        assert_nil result.tribal_enrollment_number
        assert_nil result.tribal_affiliation
      end

      test "from_fhir leaves tribal_affiliation nil when there is no tribal-affiliation extension" do
        result = Patient.from_fhir(fhir_patient)

        assert_nil result.tribal_affiliation
        assert_nil result.tribal_enrollment_number
      end

      # -- Patient.from_fhir: malformed input (#1187 round 2) -----------------

      test "from_fhir leaves tribal_affiliation nil when valueCodeableConcept is a String" do
        # "text" inside the string must not be read as the concept's text.
        result = nil
        assert_nothing_raised { result = Patient.from_fhir(fhir_patient(complex_extension("SYNTHETIC free text coding"))) }

        assert_nil result.tribal_affiliation
        assert_nil result.tribal_enrollment_number
      end

      test "from_fhir leaves tribal_affiliation nil when valueCodeableConcept is an Array" do
        result = nil
        assert_nothing_raised do
          result = Patient.from_fhir(fhir_patient(complex_extension([ { "text" => TRIBE_NAME } ])))
        end

        assert_nil result.tribal_affiliation
      end

      test "from_fhir does not raise when a coding element is not a Hash" do
        [ "SYNTHETIC display", 901, nil, [ "display" ] ].each do |junk|
          result = nil
          assert_nothing_raised do
            result = Patient.from_fhir(fhir_patient(complex_extension({ "coding" => [ junk ] })))
          end
          assert_nil result.tribal_affiliation, "coding #{junk.inspect}"
        end
      end

      test "from_fhir does not raise when coding is not an Array of Hashes and a valid coding follows" do
        concept = { "coding" => [ "SYNTHETIC junk", { "system" => IHS_TRIBE_SYSTEM, "code" => TRIBE_CODE,
                                                      "display" => TRIBE_NAME } ] }
        result = nil
        assert_nothing_raised { result = Patient.from_fhir(fhir_patient(complex_extension(concept))) }

        # nil, or the valid later display; never the junk.
        assert_includes [ nil, TRIBE_NAME ], result.tribal_affiliation
      end

      test "from_fhir reads the text even when a coding element is not a Hash" do
        concept = { "coding" => [ "SYNTHETIC junk" ], "text" => TRIBE_NAME }
        result = nil
        assert_nothing_raised { result = Patient.from_fhir(fhir_patient(complex_extension(concept))) }

        assert_equal TRIBE_NAME, result.tribal_affiliation
      end

      test "from_fhir leaves tribal_affiliation nil when the only sub-extension is nil" do
        ext = { "url" => US_CORE_TRIBAL_URL, "extension" => [ nil ] }
        result = nil
        assert_nothing_raised { result = Patient.from_fhir(fhir_patient(ext)) }

        assert_nil result.tribal_affiliation
      end

      test "from_fhir does not raise on a nil sub-extension before a valid tribalAffiliation" do
        concept = { "text" => TRIBE_NAME }
        ext = { "url" => US_CORE_TRIBAL_URL,
                "extension" => [ nil, { "url" => "tribalAffiliation", "valueCodeableConcept" => concept } ] }
        result = nil
        assert_nothing_raised { result = Patient.from_fhir(fhir_patient(ext)) }

        # nil, or the valid later value.
        assert_includes [ nil, TRIBE_NAME ], result.tribal_affiliation
      end

      test "from_fhir does not raise when the sub-extension list is not an Array of Hashes" do
        [ "SYNTHETIC junk", [ "SYNTHETIC junk" ], [ 42 ] ].each do |junk|
          ext = { "url" => US_CORE_TRIBAL_URL, "extension" => junk }
          result = nil
          assert_nothing_raised { result = Patient.from_fhir(fhir_patient(ext)) }
          assert_nil result.tribal_affiliation, "extension #{junk.inspect}"
        end
      end

      test "from_fhir reads the new-shape extension when an old-shape valueString extension comes first" do
        old_shape = { "url" => "http://hl7.org/fhir/us/core/StructureDefinition/tribal-affiliation",
                      "valueString" => ENROLLMENT_NUMBER }
        concept = { "coding" => [ { "system" => IHS_TRIBE_SYSTEM, "code" => TRIBE_CODE } ], "text" => TRIBE_NAME }
        result = Patient.from_fhir(fhir_patient(old_shape, complex_extension(concept)))

        assert_equal TRIBE_NAME, result.tribal_affiliation
        assert_nil result.tribal_enrollment_number
      end
    end
  end
end
