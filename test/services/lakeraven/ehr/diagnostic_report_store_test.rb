# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DiagnosticReportStoreTest < ActiveSupport::TestCase
      teardown do
        DiagnosticReportStore.reset_instance!
      end

      def build_report(ien:, patient_dfn:)
        DiagnosticReport.new(
          ien: ien,
          patient_dfn: patient_dfn,
          code_display: "Synthetic panel #{ien}",
          status: "final",
          category: "LAB"
        )
      end

      # =============================================================================
      # SEED AND READ
      # =============================================================================

      test "seed! then all, count, for_patient and find expose seeded reports" do
        report = build_report(ien: "dr-1", patient_dfn: "100")
        store = DiagnosticReportStore.instance
        store.seed!([ report ])

        assert_equal 1, store.count
        assert_equal [ report ], store.all
        assert_equal [ report ], store.for_patient("100")
        assert_equal [ report ], store.for_patient(100)
        assert_equal report, store.find("dr-1")
      end

      # =============================================================================
      # OWNER (patient_dfn)
      # =============================================================================

      test "add raises and stores nothing when patient_dfn is blank" do
        report = DiagnosticReport.new(
          ien: "dr-blank",
          patient_dfn: nil,
          code_display: "Blank owner",
          status: "final",
          category: "LAB"
        )
        store = DiagnosticReportStore.instance

        assert_raises(ArgumentError) { store.add(report) }
        assert_equal 0, store.count
      end

      test "seed! raises when any report has blank patient_dfn" do
        bad = DiagnosticReport.new(
          ien: "dr-bad",
          patient_dfn: "",
          code_display: "No owner",
          status: "final",
          category: "LAB"
        )
        store = DiagnosticReportStore.instance

        assert_raises(ArgumentError) { store.seed!([ bad ]) }
        assert_equal 0, store.count
      end

      # =============================================================================
      # IDEMPOTENT RE-SEED
      # =============================================================================

      test "seed! replaces contents so seeding the same records twice leaves one copy" do
        report = build_report(ien: "1", patient_dfn: "50")
        store = DiagnosticReportStore.instance
        records = [ report ]

        store.seed!(records)
        store.seed!(records)

        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      test "seed! replaces prior contents rather than appending" do
        first = build_report(ien: "a", patient_dfn: "10")
        second = build_report(ien: "b", patient_dfn: "20")
        store = DiagnosticReportStore.instance

        store.seed!([ first ])
        store.seed!([ second ])

        assert_equal 1, store.count
        assert_equal [ second ], store.all
        refute_includes store.all, first
      end

      test "mutating the seeded array after seed! does not change the store" do
        report = build_report(ien: "7", patient_dfn: "88")
        store = DiagnosticReportStore.instance
        records = [ report ]

        store.seed!(records)
        records << build_report(ien: "99", patient_dfn: "88")
        records.clear

        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      # =============================================================================
      # RESET
      # =============================================================================

      test "reset_instance! yields a fresh empty store" do
        store = DiagnosticReportStore.instance
        store.seed!([ build_report(ien: "9", patient_dfn: "1") ])

        DiagnosticReportStore.reset_instance!

        fresh = DiagnosticReportStore.instance
        assert_equal 0, fresh.count
        assert_empty fresh.all
        assert_nil fresh.find("9")
        assert_empty fresh.for_patient("1")
      end

      # =============================================================================
      # ALL RETURNS A COPY
      # =============================================================================

      test "all returns a copy so mutating it does not change the store" do
        report = build_report(ien: "7", patient_dfn: "88")
        store = DiagnosticReportStore.instance
        store.seed!([ report ])

        snapshot = store.all
        snapshot << build_report(ien: "99", patient_dfn: "88")

        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      # =============================================================================
      # MISSED LOOKUPS
      # =============================================================================

      test "for_patient returns empty array when no reports match" do
        store = DiagnosticReportStore.instance
        store.seed!([ build_report(ien: "1", patient_dfn: "100") ])

        assert_empty store.for_patient("200")
        assert_empty store.for_patient(200)
      end

      test "for_patient returns empty array for blank patient key" do
        store = DiagnosticReportStore.instance
        store.seed!([ build_report(ien: "1", patient_dfn: "100") ])

        assert_empty store.for_patient(nil)
        assert_empty store.for_patient("")
      end

      test "find returns nil when no report matches id" do
        store = DiagnosticReportStore.instance
        store.seed!([ build_report(ien: "1", patient_dfn: "100") ])

        assert_nil store.find("missing")
      end

      # =============================================================================
      # PATIENT ISOLATION
      # =============================================================================

      test "for_patient never returns reports belonging to another patient" do
        for_100 = build_report(ien: "1", patient_dfn: "100")
        for_200 = build_report(ien: "2", patient_dfn: "200")
        store = DiagnosticReportStore.instance
        store.seed!([ for_100, for_200 ])

        results = store.for_patient("100")

        assert_equal [ for_100 ], results
        refute_includes results, for_200
      end

      # =============================================================================
      # SEED VALIDATION
      # =============================================================================

      test "add nil raises and leaves prior contents intact" do
        report = build_report(ien: "1", patient_dfn: "10")
        store = DiagnosticReportStore.instance
        store.seed!([ report ])

        assert_raises(ArgumentError) { store.add(nil) }
        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      test "seed! with nil element raises and leaves prior contents intact" do
        report = build_report(ien: "1", patient_dfn: "10")
        store = DiagnosticReportStore.instance
        store.seed!([ report ])

        assert_raises(ArgumentError) { store.seed!([ nil ]) }
        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      test "seed! with nil argument raises and leaves prior contents intact" do
        report = build_report(ien: "1", patient_dfn: "10")
        store = DiagnosticReportStore.instance
        store.seed!([ report ])

        assert_raises(ArgumentError) { store.seed!(nil) }
        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      test "seed! with non-array argument raises and leaves prior contents intact" do
        report = build_report(ien: "1", patient_dfn: "10")
        store = DiagnosticReportStore.instance
        store.seed!([ report ])

        assert_raises(ArgumentError) { store.seed!("not-an-array") }
        assert_equal 1, store.count
        assert_equal [ report ], store.all
      end

      test "seed! rolls back when one record fails validation leaving prior contents intact" do
        other = build_report(ien: "99", patient_dfn: "99")
        good = build_report(ien: "1", patient_dfn: "10")
        bad = DiagnosticReport.new(
          ien: "2",
          patient_dfn: nil,
          code_display: "Bad owner",
          status: "final",
          category: "LAB"
        )
        store = DiagnosticReportStore.instance
        store.seed!([ other ])

        assert_raises(ArgumentError) { store.seed!([ good, bad ]) }
        assert_equal 1, store.count
        assert_equal [ other ], store.all
      end

      test "seed! rolls back when first record fails validation leaving prior contents intact" do
        other = build_report(ien: "99", patient_dfn: "99")
        good = build_report(ien: "1", patient_dfn: "10")
        bad = DiagnosticReport.new(
          ien: "2",
          patient_dfn: nil,
          code_display: "Bad owner",
          status: "final",
          category: "LAB"
        )
        store = DiagnosticReportStore.instance
        store.seed!([ other ])

        assert_raises(ArgumentError) { store.seed!([ bad, good ]) }
        assert_equal 1, store.count
        assert_equal [ other ], store.all
      end
    end
  end
end
