# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CarePlanStoreTest < ActiveSupport::TestCase
      teardown do
        CarePlanStore.reset_instance!
      end

      def build_care_plan(ien:, patient_dfn:)
        CarePlan.new(
          ien: ien,
          patient_dfn: patient_dfn,
          title: "Plan #{ien}",
          status: "active",
          intent: "plan"
        )
      end

      # =============================================================================
      # SEED AND READ
      # =============================================================================

      test "seed! then all, count, for_patient and find expose seeded care plans" do
        plan = build_care_plan(ien: "cp-1", patient_dfn: "100")
        store = CarePlanStore.instance
        store.seed!([ plan ])

        assert_equal 1, store.count
        assert_equal [ plan ], store.all
        assert_equal [ plan ], store.for_patient("100")
        assert_equal [ plan ], store.for_patient(100)
        assert_equal plan, store.find("cp-1")
      end

      # =============================================================================
      # OWNER (patient_dfn)
      # =============================================================================

      test "add raises and stores nothing when patient_dfn is blank" do
        plan = CarePlan.new(
          ien: "cp-blank",
          patient_dfn: "",
          title: "Blank owner",
          status: "active",
          intent: "plan"
        )
        store = CarePlanStore.instance

        assert_raises(ArgumentError) { store.add(plan) }
        assert_equal 0, store.count
      end

      test "seed! raises when any care plan has blank patient_dfn" do
        bad = CarePlan.new(
          ien: "cp-bad",
          patient_dfn: nil,
          title: "No owner",
          status: "active",
          intent: "plan"
        )
        store = CarePlanStore.instance

        assert_raises(ArgumentError) { store.seed!([ bad ]) }
        assert_equal 0, store.count
      end

      # =============================================================================
      # IDEMPOTENT RE-SEED
      # =============================================================================

      test "seed! replaces contents so seeding the same records twice leaves one copy" do
        plan = build_care_plan(ien: "1", patient_dfn: "50")
        store = CarePlanStore.instance
        records = [ plan ]

        store.seed!(records)
        store.seed!(records)

        assert_equal 1, store.count
        assert_equal [ plan ], store.all
      end

      test "seed! replaces prior contents rather than appending" do
        first = build_care_plan(ien: "a", patient_dfn: "10")
        second = build_care_plan(ien: "b", patient_dfn: "20")
        store = CarePlanStore.instance

        store.seed!([ first ])
        store.seed!([ second ])

        assert_equal 1, store.count
        assert_equal [ second ], store.all
        refute_includes store.all, first
      end

      test "mutating the seeded array after seed! does not change the store" do
        plan = build_care_plan(ien: "7", patient_dfn: "88")
        store = CarePlanStore.instance
        records = [ plan ]

        store.seed!(records)
        records << build_care_plan(ien: "99", patient_dfn: "88")
        records.clear

        assert_equal 1, store.count
        assert_equal [ plan ], store.all
      end

      # =============================================================================
      # RESET
      # =============================================================================

      test "reset_instance! yields a fresh empty store" do
        store = CarePlanStore.instance
        store.seed!([ build_care_plan(ien: "9", patient_dfn: "1") ])

        CarePlanStore.reset_instance!

        fresh = CarePlanStore.instance
        assert_equal 0, fresh.count
        assert_empty fresh.all
        assert_nil fresh.find("9")
        assert_empty fresh.for_patient("1")
      end

      # =============================================================================
      # ALL RETURNS A COPY
      # =============================================================================

      test "all returns a copy so mutating it does not change the store" do
        plan = build_care_plan(ien: "7", patient_dfn: "88")
        store = CarePlanStore.instance
        store.seed!([ plan ])

        snapshot = store.all
        snapshot << build_care_plan(ien: "99", patient_dfn: "88")

        assert_equal 1, store.count
        assert_equal [ plan ], store.all
      end

      # =============================================================================
      # MISSED LOOKUPS
      # =============================================================================

      test "for_patient returns empty array when no care plans match" do
        store = CarePlanStore.instance
        store.seed!([ build_care_plan(ien: "1", patient_dfn: "100") ])

        assert_empty store.for_patient("200")
        assert_empty store.for_patient(200)
      end

      test "for_patient returns empty array for blank patient key" do
        store = CarePlanStore.instance
        store.seed!([ build_care_plan(ien: "1", patient_dfn: "100") ])

        assert_empty store.for_patient(nil)
        assert_empty store.for_patient("")
      end

      test "find returns nil when no care plan matches id" do
        store = CarePlanStore.instance
        store.seed!([ build_care_plan(ien: "1", patient_dfn: "100") ])

        assert_nil store.find("missing")
      end

      # =============================================================================
      # PATIENT ISOLATION
      # =============================================================================

      test "for_patient never returns care plans belonging to another patient" do
        for_100 = build_care_plan(ien: "1", patient_dfn: "100")
        for_200 = build_care_plan(ien: "2", patient_dfn: "200")
        store = CarePlanStore.instance
        store.seed!([ for_100, for_200 ])

        results = store.for_patient("100")

        assert_equal [ for_100 ], results
        refute_includes results, for_200
      end

      # =============================================================================
      # SEED VALIDATION
      # =============================================================================

      test "seed! with nil argument raises and leaves prior contents intact" do
        plan = build_care_plan(ien: "1", patient_dfn: "10")
        store = CarePlanStore.instance
        store.seed!([ plan ])

        assert_raises(ArgumentError) { store.seed!(nil) }
        assert_equal 1, store.count
        assert_equal [ plan ], store.all
      end

      test "seed! with non-array argument raises and leaves prior contents intact" do
        plan = build_care_plan(ien: "1", patient_dfn: "10")
        store = CarePlanStore.instance
        store.seed!([ plan ])

        assert_raises(ArgumentError) { store.seed!("not-an-array") }
        assert_equal 1, store.count
        assert_equal [ plan ], store.all
      end

      test "seed! rolls back when one record fails validation leaving prior contents intact" do
        good = build_care_plan(ien: "1", patient_dfn: "10")
        bad = CarePlan.new(
          ien: "2",
          patient_dfn: "",
          title: "Bad owner",
          status: "active",
          intent: "plan"
        )
        store = CarePlanStore.instance
        store.seed!([ good ])

        assert_raises(ArgumentError) { store.seed!([ good, bad ]) }
        assert_equal 1, store.count
        assert_equal [ good ], store.all
      end
    end
  end
end
