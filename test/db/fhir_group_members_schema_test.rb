# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Pins the persistence layer for bulk-export cohort membership (#216).
    class FhirGroupMembersSchemaTest < ActiveSupport::TestCase
      TABLE = :lakeraven_ehr_fhir_group_members
      GROUP_ID_CONSTRAINT = "fhir_group_member_group_id_fhir_id"
      PATIENT_DFN_CONSTRAINT = "fhir_group_member_patient_dfn_format"
      VALID_GROUP_ID = "cohort-synthetic-db-valid"
      VALID_PATIENT_DFN = "900001"

      setup { FhirGroupMember.delete_all }

      test "schema defines lakeraven_ehr_fhir_group_members with required columns" do
        connection = ActiveRecord::Base.connection

        assert connection.table_exists?(TABLE),
               "expected migration to create #{TABLE}"

        assert connection.column_exists?(TABLE, :group_id)
        assert connection.column_exists?(TABLE, :patient_dfn)
        assert connection.column_exists?(TABLE, :created_at)
        assert connection.column_exists?(TABLE, :updated_at)

        group_id = connection.columns(TABLE).find { |c| c.name == "group_id" }
        patient_dfn = connection.columns(TABLE).find { |c| c.name == "patient_dfn" }

        refute group_id.null, "group_id must be NOT NULL"
        refute patient_dfn.null, "patient_dfn must be NOT NULL"
      end

      test "schema enforces unique membership per group and patient" do
        connection = ActiveRecord::Base.connection

        assert connection.index_exists?(
          TABLE,
          %i[group_id patient_dfn],
          unique: true
        ), "expected unique index on [group_id, patient_dfn]"
      end

      test "schema enforces group_id and patient_dfn invariants with named check constraints" do
        names = connection.check_constraints(TABLE.to_s).map(&:name)

        assert_includes names, GROUP_ID_CONSTRAINT
        assert_includes names, PATIENT_DFN_CONSTRAINT
      end

      test "database accepts valid membership via insert_all" do
        assert_nothing_raised do
          insert_raw(group_id: VALID_GROUP_ID, patient_dfn: VALID_PATIENT_DFN)
        end

        assert_equal 1, FhirGroupMember.where(group_id: VALID_GROUP_ID, patient_dfn: VALID_PATIENT_DFN).count
      end

      [ ("a" * 65), "x/y", "" ].each do |invalid_group_id|
        test "database rejects insert_all with invalid group_id #{invalid_group_id.inspect}" do
          assert_raises(ActiveRecord::StatementInvalid) do
            insert_raw(group_id: invalid_group_id, patient_dfn: VALID_PATIENT_DFN)
          end
        end
      end

      [ "01", "0", "x/../7", "" ].each do |invalid_patient_dfn|
        test "database rejects insert_all with invalid patient_dfn #{invalid_patient_dfn.inspect}" do
          assert_raises(ActiveRecord::StatementInvalid) do
            insert_raw(group_id: VALID_GROUP_ID, patient_dfn: invalid_patient_dfn)
          end
        end
      end

      test "database rejects update_column that bypasses model validations for patient_dfn" do
        row = FhirGroupMember.create!(group_id: VALID_GROUP_ID, patient_dfn: "900010")

        assert_raises(ActiveRecord::StatementInvalid) do
          FhirGroupMember.transaction(requires_new: true) do
            row.update_column(:patient_dfn, "01")
          end
        end
      end

      test "database rejects update_column that bypasses model validations for group_id" do
        row = FhirGroupMember.create!(group_id: "cohort-synthetic-db-other", patient_dfn: VALID_PATIENT_DFN)

        assert_raises(ActiveRecord::StatementInvalid) do
          FhirGroupMember.transaction(requires_new: true) do
            row.update_column(:group_id, "x/y")
          end
        end
      end

      private

      def connection
        ActiveRecord::Base.connection
      end

      # A rejected statement aborts the enclosing transaction in Postgres; the
      # savepoint keeps the test transaction (and teardown) usable afterwards.
      def insert_raw(group_id:, patient_dfn:)
        now = Time.current
        FhirGroupMember.transaction(requires_new: true) do
          FhirGroupMember.insert_all(
            [ {
              group_id: group_id,
              patient_dfn: patient_dfn,
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end
end
