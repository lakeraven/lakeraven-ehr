# frozen_string_literal: true

module Lakeraven
  module EHR
    module Ecr
      # Transmits eICR (electronic Initial Case Report) to public health
      # agencies via eCLRS or equivalent adapter.
      # ONC § 170.315(f)(5) — Electronic Case Reporting
      class EclrsTransmissionService
        def initialize(adapter:)
          @adapter = adapter
        end

        def submit(eicr_xml:, patient_dfn:, provider_duz:)
          result = @adapter.transmit(eicr_xml)

          if result[:success]
            AuditEvent.create!(
              event_type: "application",
              action: "C",
              outcome: "0",
              agent_who_type: "Practitioner",
              agent_who_identifier: provider_duz,
              entity_id: result[:tracking_id],
              entity_type: "eICR",
              entity_identifier: result[:tracking_id],
              outcome_desc: "ecr.case_report.submitted for patient #{patient_dfn}"
            )
          end

          result
        end
      end
    end
  end
end
