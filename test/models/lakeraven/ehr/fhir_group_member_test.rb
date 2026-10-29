# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FhirGroupMemberTest < ActiveSupport::TestCase
      GROUP_ID = "cohort-synthetic-a"
      DFN_A = "900001"
      DFN_B = "900002"
      DFN_C = "900003"

      setup do
        ::Lakeraven::EHR::FhirGroupMember.delete_all
      end

      test "requires group_id and patient_dfn" do
        member = ::Lakeraven::EHR::FhirGroupMember.new(group_id: "", patient_dfn: "")
        refute member.valid?
        assert_includes member.errors[:group_id], "can't be blank"
        assert_includes member.errors[:patient_dfn], "can't be blank"
      end

      test "enforces uniqueness of patient_dfn within a group" do
        ::Lakeraven::EHR::FhirGroupMember.create!(group_id: GROUP_ID, patient_dfn: DFN_A)
        duplicate = ::Lakeraven::EHR::FhirGroupMember.new(group_id: GROUP_ID, patient_dfn: DFN_A)

        refute duplicate.valid?
        assert_includes duplicate.errors[:patient_dfn], "has already been taken"
      end

      test "members_of returns rows ordered by patient_dfn" do
        ::Lakeraven::EHR::FhirGroupMember.create!(group_id: GROUP_ID, patient_dfn: DFN_C)
        ::Lakeraven::EHR::FhirGroupMember.create!(group_id: GROUP_ID, patient_dfn: DFN_A)
        ::Lakeraven::EHR::FhirGroupMember.create!(group_id: GROUP_ID, patient_dfn: DFN_B)
        ::Lakeraven::EHR::FhirGroupMember.create!(group_id: "cohort-synthetic-other", patient_dfn: "900099")

        dfns = ::Lakeraven::EHR::FhirGroupMember.members_of(GROUP_ID).map(&:patient_dfn)

        assert_equal [ DFN_A, DFN_B, DFN_C ], dfns
      end

      test "members_of returns none for an unknown group id" do
        ::Lakeraven::EHR::FhirGroupMember.create!(group_id: GROUP_ID, patient_dfn: DFN_A)

        assert_empty ::Lakeraven::EHR::FhirGroupMember.members_of("cohort-synthetic-unknown")
      end
    end
  end
end
