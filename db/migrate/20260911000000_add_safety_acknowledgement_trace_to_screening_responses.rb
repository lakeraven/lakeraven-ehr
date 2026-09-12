# frozen_string_literal: true

# A self-harm disclosure may only be stored once a clinician has acknowledged
# the safety prompt — so the row must say WHEN that happened and WHO did it.
# Without this, a record written by a clinician who did the risk assessment is
# byte-identical to one written by a caller that slipped past the gate.
class AddSafetyAcknowledgementTraceToScreeningResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_screening_responses, :safety_acknowledged_at, :datetime
    add_column :lakeraven_ehr_screening_responses, :safety_acknowledged_by, :string
  end
end
