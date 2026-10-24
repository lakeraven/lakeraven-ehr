# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncounterStoreTest < ActiveSupport::TestCase
      teardown do
        EncounterStore.reset_instance!
      end

      def build_encounter(ien:, patient_dfn:)
        Encounter.new(
          ien: ien,
          patient_dfn: patient_dfn,
          status: "finished",
          class_code: "AMB"
        )
      end

      # =============================================================================
      # SEED AND READ
      # =============================================================================

      test "seed! then all, count, for_patient and find expose seeded encounters" do
        enc = build_encounter(ien: 42, patient_dfn: 100)
        store = EncounterStore.instance
        store.seed!([enc])

        assert_equal 1, store.count
        assert_equal [enc], store.all
        assert_equal [enc], store.for_patient(100)
        assert_equal enc, store.find(42)
        assert_equal enc, store.find("42")
      end

      # =============================================================================
      # IDEMPOTENT RE-SEED
      # =============================================================================

      test "seed! replaces contents so seeding the same records twice leaves one copy" do
        enc = build_encounter(ien: 1, patient_dfn: 50)
        store = EncounterStore.instance
        records = [enc]

        store.seed!(records)
        store.seed!(records)

        assert_equal 1, store.count
        assert_equal [enc], store.all
      end

      test "seed! replaces prior contents rather than appending" do
        first = build_encounter(ien: 1, patient_dfn: 10)
        second = build_encounter(ien: 2, patient_dfn: 20)
        store = EncounterStore.instance

        store.seed!([first])
        store.seed!([second])

        assert_equal 1, store.count
        assert_equal [second], store.all
        refute_includes store.all, first
      end

      # =============================================================================
      # RESET
      # =============================================================================

      test "reset_instance! yields a fresh empty store" do
        store = EncounterStore.instance
        store.seed!([build_encounter(ien: 9, patient_dfn: 1)])

        EncounterStore.reset_instance!

        fresh = EncounterStore.instance
        assert_equal 0, fresh.count
        assert_empty fresh.all
        assert_nil fresh.find(9)
        assert_empty fresh.for_patient(1)
      end

      # =============================================================================
      # ALL RETURNS A COPY
      # =============================================================================

      test "all returns a copy so mutating it does not change the store" do
        enc = build_encounter(ien: 7, patient_dfn: 88)
        store = EncounterStore.instance
        store.seed!([enc])

        snapshot = store.all
        snapshot << build_encounter(ien: 99, patient_dfn: 88)

        assert_equal 1, store.count
        assert_equal [enc], store.all
      end

      # =============================================================================
      # MISSED LOOKUPS
      # =============================================================================

      test "for_patient returns empty array when no encounters match" do
        store = EncounterStore.instance
        store.seed!([build_encounter(ien: 1, patient_dfn: 100)])

        assert_empty store.for_patient(200)
        assert_empty store.for_patient("200")
      end

      test "find returns nil when no encounter matches id" do
        store = EncounterStore.instance
        store.seed!([build_encounter(ien: 1, patient_dfn: 100)])

        assert_nil store.find("missing")
        assert_nil store.find(999)
      end

      # =============================================================================
      # PATIENT ISOLATION
      # =============================================================================

      test "for_patient never returns encounters belonging to another patient" do
        for_100 = build_encounter(ien: 1, patient_dfn: 100)
        for_200 = build_encounter(ien: 2, patient_dfn: 200)
        store = EncounterStore.instance
        store.seed!([for_100, for_200])

        results = store.for_patient(100)

        assert_equal [for_100], results
        refute_includes results, for_200
      end
    end
  end
end
