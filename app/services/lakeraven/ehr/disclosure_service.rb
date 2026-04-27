# frozen_string_literal: true

module Lakeraven
  module EHR
    # DisclosureService -- Record and query PHI disclosures
    #
    # ONC 170.315(d)(11) -- Accounting of Disclosures
    # HIPAA 164.528 -- Right to an Accounting of Disclosures
    class DisclosureService
      def self.record(patient_dfn:, recipient_name:, purpose:, data_disclosed:,
                      disclosed_by:, recipient_type: nil, recipient_npi: nil,
                      disclosed_at: nil, disclosed_by_name: nil,
                      authorization_method: nil, consent_reference: nil)
        Disclosure.transaction do
          disclosure = Disclosure.create!(
            patient_dfn: patient_dfn,
            recipient_name: recipient_name,
            recipient_type: recipient_type,
            recipient_npi: recipient_npi,
            purpose: purpose,
            data_disclosed: data_disclosed,
            disclosed_by: disclosed_by,
            disclosed_by_name: disclosed_by_name,
            disclosed_at: disclosed_at || Time.current,
            authorization_method: authorization_method,
            consent_reference: consent_reference
          )

          record_audit_event(disclosure)
          disclosure
        end
      end

      def self.accounting(patient_dfn)
        Disclosure.accounting_for_patient(patient_dfn)
      end

      def self.export_report(patient_dfn)
        disclosures = accounting(patient_dfn)
        {
          patient_dfn: patient_dfn,
          report_type: "accounting_of_disclosures",
          period_start: Disclosure::RETENTION_PERIOD.ago.iso8601,
          period_end: Time.current.iso8601,
          generated_at: Time.current.iso8601,
          total_disclosures: disclosures.count,
          disclosures: disclosures.map { |d| serialize_disclosure(d) }
        }
      end

      def self.serialize_disclosure(disclosure)
        {
          id: disclosure.id,
          date: disclosure.disclosed_at.iso8601,
          recipient: {
            name: disclosure.recipient_name,
            type: disclosure.recipient_type,
            npi: disclosure.recipient_npi
          },
          purpose: disclosure.purpose,
          data_disclosed: disclosure.data_disclosed,
          disclosed_by: disclosure.disclosed_by,
          disclosed_by_name: disclosure.disclosed_by_name,
          authorization_method: disclosure.authorization_method,
          consent_reference: disclosure.consent_reference
        }
      end
      private_class_method :serialize_disclosure

      def self.record_audit_event(disclosure)
        AuditEvent.create!(
          event_type: "application",
          action: "C",
          outcome: "0",
          agent_who_type: "Practitioner",
          agent_who_identifier: disclosure.disclosed_by,
          agent_name: disclosure.disclosed_by_name || disclosure.disclosed_by,
          entity_id: disclosure.id.to_s,
          entity_type: "Disclosure",
          entity_identifier: disclosure.id.to_s,
          outcome_desc: "PHI disclosed to #{disclosure.recipient_name} " \
                        "for #{disclosure.purpose} (patient #{disclosure.patient_dfn})"
        )
      end
      private_class_method :record_audit_event
    end
  end
end
