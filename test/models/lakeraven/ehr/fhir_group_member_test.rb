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
        assert member.errors[:group_id].present?
        assert member.errors[:patient_dfn].present?
      end

      test "group_id must match FHIR id grammar used by Group read" do
        invalid_ids = [ ("a" * 65), "x/y", "a b", "" ]
        invalid_ids.each do |group_id|
          member = ::Lakeraven::EHR::FhirGroupMember.new(group_id: group_id, patient_dfn: DFN_A)
          refute member.valid?, "expected group_id #{group_id.inspect} to be invalid"
          assert member.errors[:group_id].present?, member.errors.full_messages.inspect
        end
      end

      test "patient_dfn must be a positive integer string without leading zeros" do
        invalid_dfns = [ "abc", "01", "0", "-1", "" ]
        invalid_dfns.each do |patient_dfn|
          member = ::Lakeraven::EHR::FhirGroupMember.new(group_id: GROUP_ID, patient_dfn: patient_dfn)
          refute member.valid?, "expected patient_dfn #{patient_dfn.inspect} to be invalid"
          assert member.errors[:patient_dfn].present?, member.errors.full_messages.inspect
        end
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
