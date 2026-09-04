# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Condition.from_problem_hashes against the VERIFIED ORQQPL LIST wire
    # (LIST^ORQQPL: ien/description/status/icd_code/onset_date/
    # last_modified — status "A"/"I"). Guards the fabricated-wire failure:
    # the old swapped mapping fed narrative text into :status, and the old
    # builder defaulted any unrecognized status to "active" — so a real
    # INACTIVE problem came back active.
    class ConditionProblemWireTest < ActiveSupport::TestCase
      def build(rows)
        Condition.from_problem_hashes(rows, patient_dfn: "1")
      end

      def inactive_row
        { ien: "102", description: "Sprain of ankle", status: "I",
          icd_code: "S93.401A", onset_date: Date.new(2018, 6, 1),
          last_modified: Date.new(2018, 6, 15) }
      end

      test "a real inactive wire row parses through rpms-rpc and never comes back active" do
        raw = RpmsRpc::DataMapper[:problem_list]
              .parse_one("102^Sprain of ankle^I^S93.401A^3180601^3180615^^^^^^10")

        condition = build([ raw ]).first
        assert_equal "inactive", condition.clinical_status
        assert_equal "Sprain of ankle", condition.display
        assert_equal "S93.401A", condition.code
        refute condition.active?, "a real inactive row must NOT come back active"
      end

      test "an unrecognized status yields no clinicalStatus instead of a guessed active" do
        condition = build([ inactive_row.merge(status: "$GARBAGE") ]).first

        assert_nil condition.clinical_status
        refute condition.active?
        assert_nil condition.to_fhir[:clinicalStatus]
      end

      test "verificationStatus is omitted — the wire carries problem status, not verification" do
        fhir = build([ inactive_row ]).first.to_fhir

        assert_nil fhir[:verificationStatus]
      end

      test "recordedDate is omitted — the wire date is LAST MODIFIED, not a recorded date" do
        fhir = build([ inactive_row ]).first.to_fhir

        assert_nil fhir[:recordedDate]
        assert fhir[:onsetDateTime].to_s.start_with?("2018-06-01"),
          "onset must survive from the wire's ONSET piece"
      end

      test "status codes are matched case-insensitively" do
        assert_equal "active", build([ inactive_row.merge(status: "a") ]).first.clinical_status
      end
    end
  end
end
