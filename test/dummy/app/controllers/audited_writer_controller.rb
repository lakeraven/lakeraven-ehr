# frozen_string_literal: true

# A representative AUDITED WRITER, for the fail-closed audit contract.
#
# No FHIR endpoint in the engine writes to the database today, so there is
# nothing in-tree to prove the transaction property against — and a test that
# "passes" because the action never wrote anything proves nothing at all.
# The property is not hypothetical: the screening surface (#491) records
# QuestionnaireResponses, and that is exactly where an audit failing open was
# found.
#
# So this controller exists only in the dummy host app (never shipped) and
# does the one thing the contract is about: write a row inside an audited
# action.
class AuditedWriterController < Lakeraven::EHR::ApplicationController
  # A synthetic mid-action failure, for the "an access that raises is a
  # failure, not a success" contract. Raised AFTER the write so the test also
  # proves the write rolled back.
  class SyntheticActionFailure < StandardError; end

  def create
    Lakeraven::EHR::ReconciliationSession.create!(
      patient_dfn: params[:patient_dfn].to_s,
      clinician_duz: "301",
      source_type: "test",
      status: "pending"
    )
    raise SyntheticActionFailure, "synthetic mid-action failure" if params[:explode].present?

    render json: { ok: true }, status: :created
  end

  private

  # The concern derives this from the controller name; name a real FHIR type
  # so scope checks behave like any other endpoint.
  def fhir_resource_type = "Patient"
end
