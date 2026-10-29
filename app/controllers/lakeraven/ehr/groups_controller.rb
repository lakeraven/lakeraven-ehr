# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR Group read for a bulk-export cohort (#216).
    #
    # Authorization is decided before the cohort is read. A token without
    # Patient read is the same 403 for every id, and so is a patient-bound
    # token: this read lists patients, and a bound token has no cohort it
    # may read. An unknown id, an id that cannot name a record, a cohort
    # with no rows, and a cohort whose member list the egress filter
    # empties are the same not-found. The diagnostics are fixed: the
    # caller's id is never copied into them. Quantity is the length of
    # the member list Part2EgressFilter returns.
    class GroupsController < ApplicationController
      NOT_FOUND_DIAGNOSTICS = "Group not found"

      def show
        return unless group_read_authorized?

        group_id = params[:id].to_s
        return render_group_not_found unless fhir_group_id?(group_id)

        members = FhirGroupMember.members_of(group_id)
        return render_group_not_found if members.empty?

        render_filtered_group(group_resource(group_id, members))
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

      # Patient read, then the compartment. A bound token names no patient
      # on this read, so it is refused whole. Neither check reads the cohort.
      def group_read_authorized?
        disclosed_patient_read_authorized? && authorize_patient_search!(nil)
      end

      def disclosed_patient_read_authorized?
        return true if can_read?("Patient")

        render_forbidden("Insufficient scope for reading Patient")
        false
      end

      # The filter's payload is what we send. Quantity is the length of
      # its member list. An empty member list is the same not-found as
      # an unknown cohort. A payload with no member list is rendered
      # unchanged.
      def render_filtered_group(payload)
        filtered = filter_fhir_for_egress(payload)
        return refuse_unfiltered_fhir_egress unless filtered

        members = filtered["member"]
        return render_group_not_found if members.is_a?(Array) && members.empty?

        render json: filtered, status: :ok, content_type: fhir_egress_content_type
      end

      # String keys, because the egress seam matches resourceType on the
      # hash it is given. Quantity is counted afterwards, from whatever
      # member list the filter returns.
      def group_resource(group_id, members)
        {
          "resourceType" => "Group",
          "id" => group_id,
          "type" => "person",
          "actual" => true,
          "member" => members.map { |row| member_reference(row) }
        }
      end

      # Part2EgressFilter may drop member references. Count the list it
      # returned. A payload with no member list is rendered unchanged.
      def egress_filter(payload)
        filtered = super
        members = filtered["member"] if filtered.is_a?(Hash)
        return filtered unless members.is_a?(Array)

        filtered.merge("quantity" => members.length)
      end

      def member_reference(row)
        { "entity" => { "reference" => "Patient/#{row.patient_dfn}" } }
      end
    end
  end
end
