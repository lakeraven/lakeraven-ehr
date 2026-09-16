# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Observation.from_measurement_hashes — building FHIR observations from
    # the REAL decorated-measurement rows the rpms-rpc Measurement reads
    # return. Guards against the fabricated-wire failure class: the old
    # ORQQVI mapping (TYPE^VALUE^UNITS^DATE) parsed the measurement IEN as
    # the vital type, and the old builder guessed units from a type table.
    class ObservationMeasurementTest < ActiveSupport::TestCase
      def build(rows)
        Observation.from_measurement_hashes(rows, patient_dfn: "1")
      end

      def wt_row(overrides = {})
        { measurement_ien: 5006, type: "WT", value: "150", units: "lb",
          date: Time.utc(2025, 1, 15, 8, 0), visit_ien: 9001,
          service_category: "A", capture_mode: :office,
          entered_in_error: false }.merge(overrides)
      end

      # A real ORQQVI wire row, parsed by the corrected rpms-rpc mapping and
      # decorated the way Measurement.history does. Under the OLD fabricated
      # mapping the same raw line parsed as {type: "5006", value: "WT",
      # units: "3250115.08"} — the IEN as the type — and nothing usable
      # came out; this pins the end-to-end parse.
      test "a real ORQQVI wire row builds a correct observation" do
        raw = RpmsRpc::DataMapper[:vitals].parse_one("5006^WT^3250115.08^150")
        row = raw.merge(units: "lb", date: raw[:recorded_date], entered_in_error: false)

        obs = build([ row ]).first

        refute_nil obs, "A real-shape weight row must serialize"
        assert_equal "5006", obs.ien, "id must be the V MEASUREMENT IEN"
        assert_equal "150", obs.value, "value is wire piece 4, not the type"
        assert_equal "29463-7", obs.code
        assert_equal "[lb_av]", obs.unit, "source unit 'lb' translates to UCUM"
        assert_equal raw[:recorded_date], obs.effective_datetime
        assert_equal "final", obs.status
      end

      test "a row without a source unit is dropped, never guessed from the type" do
        assert_empty build([ wt_row(units: nil) ])
        assert_empty build([ wt_row(units: "  ") ])
      end

      test "a row without a measurement IEN is dropped, never given a blank id" do
        observations = build([ wt_row(measurement_ien: nil), wt_row(measurement_ien: "") ])

        assert_empty observations
      end

      test "two same-minute readings of one type keep distinct real ids" do
        rows = [ wt_row(measurement_ien: 6401), wt_row(measurement_ien: 6402, value: "151") ]

        ids = build(rows).map(&:ien)
        assert_equal %w[6401 6402], ids
      end

      test "an untranslatable source unit rides as display text without a UCUM claim" do
        obs = build([ wt_row(units: "stone") ]).first

        fhir = obs.to_fhir
        assert_equal "stone", fhir.dig(:valueQuantity, :unit)
        assert_nil fhir.dig(:valueQuantity, :code)
        assert_nil fhir.dig(:valueQuantity, :system)
      end

      test "entered-in-error flag from the wire drives status" do
        rows = [ wt_row(entered_in_error: true),
                 wt_row(measurement_ien: 5007, entered_in_error: false),
                 wt_row(measurement_ien: 5008, entered_in_error: nil) ]

        assert_equal %w[entered-in-error final unknown], build(rows).map(&:status)
      end

      test "a malformed blood pressure is dropped, not serialized as 0.0 components" do
        rows = [ { measurement_ien: 6001, type: "BP", value: "REFUSED", units: "mmHg",
                   date: Time.utc(2025, 2, 1, 10, 0), entered_in_error: false },
                 { measurement_ien: 6002, type: "BP", value: "120/80", units: "mmHg",
                   date: Time.utc(2025, 2, 1, 10, 5), entered_in_error: false } ]

        observations = build(rows)
        assert_equal [ "6002" ], observations.map(&:ien)
        components = observations.first.to_fhir[:component]
        assert_equal 120.0, components[0].dig(:valueQuantity, :value)
        assert_equal 80.0, components[1].dig(:valueQuantity, :value)
        assert_equal "mm[Hg]", components[0].dig(:valueQuantity, :unit)
      end

      test "canonical and GMRV-style type mnemonics both map to LOINC" do
        rows = [ wt_row(measurement_ien: 1, type: "TMP", value: "98.6", units: "F"),
                 wt_row(measurement_ien: 2, type: "T", value: "98.6", units: "F"),
                 wt_row(measurement_ien: 3, type: "PU", value: "72", units: "/min"),
                 wt_row(measurement_ien: 4, type: "P", value: "72", units: "/min") ]

        codes = build(rows).map(&:code)
        assert_equal %w[8310-5 8310-5 8867-4 8867-4], codes
      end
    end
  end
end
