# frozen_string_literal: true

module Lakeraven
  module EHR
    module Elr
      # Transmits HL7 ORU messages to public health agencies via eCLRS.
      # ONC § 170.315(f)(3) -- Electronic Laboratory Reporting
      class EclrsTransmissionService
        def initialize(adapter:)
          @adapter = adapter
        end

        def submit(oru_message:, patient_dfn:, provider_duz:)
          result = @adapter.transmit(oru_message)

          if result[:success]
            AuditEvent.create!(
              event_type: "application",
              action: "C",
              outcome: "0",
              agent_who_type: "Practitioner",
              agent_who_identifier: provider_duz,
              entity_id: result[:tracking_id],
              entity_type: "ORU",
              entity_identifier: result[:tracking_id],
              outcome_desc: "elr.lab_report.submitted for patient #{patient_dfn}"
            )
          end

          result
        end
      end
    end
  end
end
