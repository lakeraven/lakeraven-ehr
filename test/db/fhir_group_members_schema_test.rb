# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Pins the persistence layer for bulk-export cohort membership (#216).
    class FhirGroupMembersSchemaTest < ActiveSupport::TestCase
      TABLE = :lakeraven_ehr_fhir_group_members

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
    end
  end
end
