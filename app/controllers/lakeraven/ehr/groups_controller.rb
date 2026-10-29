# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR Group read for a bulk-export cohort (#216).
    #
    # An unknown id, an id that cannot name a record, and a cohort with no
    # members are the same not-found. The diagnostics are fixed: the caller's
    # id is never copied into them. Member references are Patient resources,
    # so the token needs Patient read, and a patient-bound token may not read
    # a cohort that names anyone else. The body is whatever
    # Part2EgressFilter returns.
    class GroupsController < ApplicationController
      NOT_FOUND_DIAGNOSTICS = "Group not found"

      def show
        group_id = params[:id].to_s
        return render_group_not_found unless fhir_group_id?(group_id)

        members = FhirGroupMember.members_of(group_id)
        return render_group_not_found if members.empty?
        return unless disclosed_patient_read_authorized?
        return unless group_within_patient_compartment?(members)

        render_fhir_egress(group_resource(group_id, members))
      end

      private

      # The audit log's FHIR id grammar. Checked before members_of so a
      # probe that cannot name a row never reaches the table.
      def fhir_group_id?(group_id)
        group_id.match?(FHIR_ID_PATTERN)
      end

      def render_group_not_found
        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: NOT_FOUND_DIAGNOSTICS
        )
      end

      def disclosed_patient_read_authorized?
        return true if can_read?("Patient")

        render_forbidden("Insufficient scope for reading Patient")
        false
      end

      # A patient-bound token may read a cohort made up only of itself.
      # Any other member is a cross-patient read and is refused whole.
      def group_within_patient_compartment?(members)
        return true unless patient_context_scope?

        other = members.map { |member| member.patient_dfn.to_s }.find { |dfn| dfn != bound_patient_dfn }
        return true if other.nil?

        authorize_patient_context!(other)
      end

      def bound_patient_dfn
        current_token.resource_owner_id.to_s
      end

      # String keys, because the egress seam matches resourceType on the
      # hash it is given and renders that hash unchanged — quantity stays
      # whatever the filter returned.
      def group_resource(group_id, members)
        member = members.map { |row| member_reference(row) }
        {
          "resourceType" => "Group",
          "id" => group_id,
          "type" => "person",
          "actual" => true,
          "quantity" => member.length,
          "member" => member
        }
      end

      def member_reference(row)
        { "entity" => { "reference" => "Patient/#{row.patient_dfn}" } }
      end
    end
  end
end
