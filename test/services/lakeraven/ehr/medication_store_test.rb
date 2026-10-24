# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MedicationStoreTest < ActiveSupport::TestCase
      MedicationEntry = Struct.new(:fhir_id, keyword_init: true)

      teardown do
        MedicationStore.reset_instance!
      end

      def build_medication(fhir_id:)
        MedicationEntry.new(fhir_id: fhir_id)
      end

      # =============================================================================
      # SEED AND READ
      # =============================================================================

      test "seed! then all, count and find expose seeded medications" do
        med = build_medication(fhir_id: "rxnorm-1234")
        store = MedicationStore.instance
        store.seed!([ med ])

        assert_equal 1, store.count
        assert_equal [ med ], store.all
        assert_equal med, store.find("rxnorm-1234")
        assert_equal med, store.find("rxnorm-1234".to_sym)
      end

      test "definitional store has no for_patient lookup" do
        store = MedicationStore.instance

        refute_respond_to store, :for_patient
      end

      # =============================================================================
      # IDEMPOTENT RE-SEED
      # =============================================================================

      test "seed! replaces contents so seeding the same records twice leaves one copy" do
        med = build_medication(fhir_id: "med-1")
        store = MedicationStore.instance
        records = [ med ]

        store.seed!(records)
        store.seed!(records)

        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      test "seed! replaces prior contents rather than appending" do
        first = build_medication(fhir_id: "a")
        second = build_medication(fhir_id: "b")
        store = MedicationStore.instance

        store.seed!([ first ])
        store.seed!([ second ])

        assert_equal 1, store.count
        assert_equal [ second ], store.all
        refute_includes store.all, first
      end

      test "mutating the seeded array after seed! does not change the store" do
        med = build_medication(fhir_id: "7")
        store = MedicationStore.instance
        records = [ med ]

        store.seed!(records)
        records << build_medication(fhir_id: "99")
        records.clear

        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      # =============================================================================
      # RESET
      # =============================================================================

      test "reset_instance! yields a fresh empty store" do
        store = MedicationStore.instance
        store.seed!([ build_medication(fhir_id: "9") ])

        MedicationStore.reset_instance!

        fresh = MedicationStore.instance
        assert_equal 0, fresh.count
        assert_empty fresh.all
        assert_nil fresh.find("9")
      end

      # =============================================================================
      # ALL RETURNS A COPY
      # =============================================================================

      test "all returns a copy so mutating it does not change the store" do
        med = build_medication(fhir_id: "7")
        store = MedicationStore.instance
        store.seed!([ med ])

        snapshot = store.all
        snapshot << build_medication(fhir_id: "99")

        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      # =============================================================================
      # MISSED LOOKUPS
      # =============================================================================

      test "find returns nil when no medication matches id" do
        store = MedicationStore.instance
        store.seed!([ build_medication(fhir_id: "1") ])

        assert_nil store.find("missing")
        assert_nil store.find(999)
      end

      # =============================================================================
      # FHIR ID
      # =============================================================================

      test "add raises and stores nothing when fhir_id is blank" do
        med = MedicationEntry.new(fhir_id: "")
        store = MedicationStore.instance

        assert_raises(ArgumentError) { store.add(med) }
        assert_equal 0, store.count
      end

      test "seed! raises when any medication has blank fhir_id" do
        bad = MedicationEntry.new(fhir_id: nil)
        store = MedicationStore.instance

        assert_raises(ArgumentError) { store.seed!([ bad ]) }
        assert_equal 0, store.count
      end

      # =============================================================================
      # SEED VALIDATION
      # =============================================================================

      test "add nil raises and leaves prior contents intact" do
        med = build_medication(fhir_id: "1")
        store = MedicationStore.instance
        store.seed!([ med ])

        assert_raises(ArgumentError) { store.add(nil) }
        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      test "seed! with nil element raises and leaves prior contents intact" do
        med = build_medication(fhir_id: "1")
        store = MedicationStore.instance
        store.seed!([ med ])

        assert_raises(ArgumentError) { store.seed!([ nil ]) }
        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      test "seed! with nil argument raises and leaves prior contents intact" do
        med = build_medication(fhir_id: "1")
        store = MedicationStore.instance
        store.seed!([ med ])

        assert_raises(ArgumentError) { store.seed!(nil) }
        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      test "seed! with non-array argument raises and leaves prior contents intact" do
        med = build_medication(fhir_id: "1")
        store = MedicationStore.instance
        store.seed!([ med ])

        assert_raises(ArgumentError) { store.seed!("not-an-array") }
        assert_equal 1, store.count
        assert_equal [ med ], store.all
      end

      test "seed! rolls back when one record fails validation leaving prior contents intact" do
        other = build_medication(fhir_id: "other")
        good = build_medication(fhir_id: "good")
        bad = MedicationEntry.new(fhir_id: "")
        store = MedicationStore.instance
        store.seed!([ other ])

        assert_raises(ArgumentError) { store.seed!([ good, bad ]) }
        assert_equal 1, store.count
        assert_equal [ other ], store.all
      end

      test "seed! rolls back when first record fails validation leaving prior contents intact" do
        other = build_medication(fhir_id: "other")
        good = build_medication(fhir_id: "good")
        bad = MedicationEntry.new(fhir_id: nil)
        store = MedicationStore.instance
        store.seed!([ other ])

        assert_raises(ArgumentError) { store.seed!([ bad, good ]) }
        assert_equal 1, store.count
        assert_equal [ other ], store.all
      end
    end
  end
end
