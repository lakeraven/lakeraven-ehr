# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Migrated for rpms-rpc 0.3.0 (#235). The gem removed the invented tribal
    # placeholder shapes (ACTIVE/INACTIVE "status", per-patient service-unit
    # reads, tribe-code-in-enrollment-number) and rebuilt RpmsRpc::Tribal on
    # real DDR FileMan reads. These tests now stub TribalEnrollmentGateway at
    # the API boundary and assert the model's NEW, fail-closed contract:
    #
    #   * eligibility is UNDETERMINED (never "eligible") until the
    #     eligibility_status (I/D/C/P) → determination mapping is signed off (#520);
    #   * validate is a syntactic format check ({ valid:, internal:, external: });
    #   * the tribe comes from the enrollment's TRIBE pointer (tribe_ien), not
    #     from splitting the enrollment number.
    class PatientTribalEnrollmentTest < ActiveSupport::TestCase
      def setup
        @enrolled = Patient.new(dfn: 1, name: "Anderson,Alice",
                                tribal_enrollment_number: "EXNH-12345")
        @unenrolled = Patient.new(dfn: 8, name: "Harris,Henry", tribal_enrollment_number: nil)
      end

      # Non-destructively override TribalEnrollmentGateway class methods for the
      # block, restoring the real methods (saved as Method objects) afterward —
      # remove_method would delete the `def self.` methods permanently.
      def with_gateway(**stubs)
        gw = TribalEnrollmentGateway
        originals = stubs.keys.to_h { |name| [ name, gw.method(name) ] }
        stubs.each { |name, value| gw.define_singleton_method(name) { |*| value } }
        yield
      ensure
        originals.each { |name, meth| gw.define_singleton_method(name, meth) }
      end

      # -- details -----------------------------------------------------------

      test "tribal_enrollment_details surfaces the new enrollment projection" do
        projection = { enrollment_number: "EXNH-12345", tribe_ien: 100,
                       tribe_name: "Example Native Health (EXNH)",
                       eligibility_status: "I", classification: "Direct",
                       community: "Anchorage" }
        with_gateway(enrollment_details: projection) do
          details = @enrolled.tribal_enrollment_details
          assert_equal "EXNH-12345", details[:enrollment_number]
          assert_equal "Example Native Health (EXNH)", details[:tribe_name]
          assert_equal 100, details[:tribe_ien]
        end
      end

      test "tribal_enrollment_details returns nil for an unsaved patient" do
        assert_nil Patient.new(tribal_enrollment_number: "EXNH-12345").tribal_enrollment_details
      end

      # -- validate (syntactic) ----------------------------------------------

      test "validate_tribal_enrollment surfaces the syntactic result" do
        with_gateway(validate: { valid: true, internal: "12345", external: "EXNH-12345" }) do
          result = @enrolled.validate_tribal_enrollment
          assert result[:valid]
          assert_equal "EXNH-12345", result[:external]
        end
      end

      test "validate_tribal_enrollment reports invalid for a malformed number" do
        with_gateway(validate: { valid: false, internal: nil, external: nil }) do
          refute @enrolled.validate_tribal_enrollment[:valid]
        end
      end

      test "validate_tribal_enrollment returns a reason for a missing number" do
        result = @unenrolled.validate_tribal_enrollment
        refute result[:valid]
        assert_includes result[:message], "No enrollment number"
      end

      test "tribal_enrollment_valid? reflects syntactic validity only" do
        with_gateway(validate: { valid: true }) { assert @enrolled.tribal_enrollment_valid? }
        with_gateway(validate: { valid: false }) { refute @enrolled.tribal_enrollment_valid? }
      end

      test "tribal_enrollment_valid? is false for a missing number" do
        refute @unenrolled.tribal_enrollment_valid?
      end

      # -- eligibility (FAIL CLOSED) -----------------------------------------

      test "tribal_enrollment_eligibility is undetermined and surfaces the raw status" do
        with_gateway(eligibility: { eligibility_status: "I", eligibility_status_name: "Indian",
                                    classification_ien: 1, classification: "Direct" }) do
          e = @enrolled.tribal_enrollment_eligibility
          assert_equal :undetermined, e[:determination]
          refute e[:eligible]
          assert_equal "I", e[:eligibility_status]
        end
      end

      test "tribal_enrollment_eligibility is undetermined for an unsaved patient" do
        e = Patient.new(tribal_enrollment_number: "EXNH-12345").tribal_enrollment_eligibility
        assert_equal :undetermined, e[:determination]
        refute e[:eligible]
      end

      test "tribal_enrollment_eligibility is undetermined when the read returns nothing" do
        with_gateway(eligibility: nil) do
          e = @enrolled.tribal_enrollment_eligibility
          assert_equal :undetermined, e[:determination]
          refute e[:eligible]
        end
      end

      # eligible_for_ihs_services? FAILS CLOSED: no eligibility_status confers
      # eligibility until the mapping is signed off, so it is false even when a
      # status is present.
      test "eligible_for_ihs_services? is false while the determination is undetermined" do
        with_gateway(eligibility: { eligibility_status: "I", classification: "Direct" }) do
          refute @enrolled.eligible_for_ihs_services?
        end
      end

      test "eligible_for_ihs_services? is false for no enrollment" do
        refute @unenrolled.eligible_for_ihs_services?
      end

      # PARKED on #520: asserting that a specific set code confers eligibility
      # requires the compliance-signed-off I/D/C/P → determination mapping. A
      # fabricated mapping would violate the fail-closed non-negotiable, so this
      # stays skipped rather than green-by-invention.
      test "eligible_for_ihs_services? is true once a status is determined eligible" do
        skip "eligibility_status (I/D/C/P) → IHS-eligibility mapping is a compliance " \
             "decision tracked in #520; fail-closed until signed off"
      end

      # -- service unit (undetermined; no per-patient read) ------------------

      test "enrollment_service_unit is nil until the community-linkage path exists" do
        assert_nil @enrolled.enrollment_service_unit
        assert_nil Patient.new(tribal_enrollment_number: "EXNH-12345").enrollment_service_unit
      end

      # -- tribe information (via the enrollment's TRIBE pointer) -------------

      test "tribe_information reads the TRIBE entry named by the enrollment pointer" do
        with_gateway(enrollment_details: { tribe_ien: 100 },
                     tribe_info: { ien: 100, name: "Example Native Health (EXNH)", code: "EXNH" }) do
          info = @enrolled.tribe_information
          assert_equal "EXNH", info[:code]
          assert_equal "Example Native Health (EXNH)", info[:name]
        end
      end

      test "tribe_information is nil when the enrollment names no tribe" do
        with_gateway(enrollment_details: { tribe_ien: nil }) do
          assert_nil @enrolled.tribe_information
        end
      end

      test "tribe_information is nil for a missing enrollment number" do
        assert_nil @unenrolled.tribe_information
      end

      # -- attributes --------------------------------------------------------

      test "tribal_enrollment_number attribute is accessible" do
        assert_equal "EXNH-12345", Patient.new(tribal_enrollment_number: "EXNH-12345").tribal_enrollment_number
      end

      test "tribal_affiliation attribute is accessible" do
        assert_equal "Painted Sky Nation", Patient.new(tribal_affiliation: "Painted Sky Nation").tribal_affiliation
      end

      test "service_area attribute is accessible" do
        assert_equal "Anchorage", Patient.new(service_area: "Anchorage").service_area
      end

      # -- fail-closed workflows ---------------------------------------------

      test "an unenrolled patient is not valid and not eligible" do
        refute @unenrolled.tribal_enrollment_valid?
        refute @unenrolled.eligible_for_ihs_services?
        assert_equal :undetermined, @unenrolled.tribal_enrollment_eligibility[:determination]
      end

      test "a format-valid enrollment is still not eligible without a determination" do
        with_gateway(validate: { valid: true },
                     eligibility: { eligibility_status: "I", classification: "Direct" }) do
          assert @enrolled.tribal_enrollment_valid?
          refute @enrolled.eligible_for_ihs_services?
        end
      end

      test "handles empty string vs nil for the enrollment number" do
        refute Patient.new(tribal_enrollment_number: nil).tribal_enrollment_valid?
        refute Patient.new(tribal_enrollment_number: "").tribal_enrollment_valid?
      end
    end
  end
end
