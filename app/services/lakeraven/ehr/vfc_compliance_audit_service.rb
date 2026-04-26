# frozen_string_literal: true

module Lakeraven
  module EHR
    # VfcComplianceAuditService - Stateless VFC compliance auditor.
    # Uses DI for data access (patient_searcher, immunization_lister, lot_lister).
    class VfcComplianceAuditService
      VFC_ELIGIBLE_CODES = %w[V02 V03 V04 V05 V06 V07].freeze

      VfcComplianceReport = Struct.new(
        :date_range, :facility, :generated_at,
        :immunization_records, :summary_statistics, :compliance_flags,
        keyword_init: true
      ) do
        def findings
          compliance_flags
        end

        def compliant?
          compliance_flags.empty?
        end
      end

      class << self
        def generate_report(date_range:, facility_ien: nil, agent_id:,
                            patient_searcher: nil, immunization_lister: nil, lot_lister: nil)
          data_errors = []

          immunizations = gather_immunizations(date_range, data_errors, patient_searcher, immunization_lister)
          lots = gather_lots(facility_ien: facility_ien, data_errors: data_errors, lot_lister: lot_lister)
          lot_index = lots.index_by { |l| l[:lot_number] }

          if facility_ien.present?
            facility_lot_numbers = lots
              .select { |l| l[:facility_ien] == facility_ien }
              .map { |l| l[:lot_number] }
              .to_set
            immunizations = immunizations.select { |imm| facility_lot_numbers.include?(imm[:lot_number]) }
          end

          flags = evaluate_compliance(immunizations, lot_index)

          data_errors.each do |error|
            flags << { type: "data_fetch_error", record_ien: nil, description: error }
          end

          stats = compute_statistics(immunizations)
          stats[:data_complete] = data_errors.empty?

          report = VfcComplianceReport.new(
            date_range: date_range,
            facility: facility_ien,
            generated_at: Time.current,
            immunization_records: immunizations,
            summary_statistics: stats,
            compliance_flags: flags
          )

          record_audit(agent_id, date_range, facility_ien)
          report
        end

        private

        def gather_immunizations(date_range, data_errors, patient_searcher, immunization_lister)
          searcher = patient_searcher || default_patient_searcher
          lister = immunization_lister || default_immunization_lister

          patient_list = begin
            searcher.call("")
          rescue => e
            data_errors << "Patient list unavailable: #{e.class}"
            return []
          end
          return [] unless patient_list.is_a?(Array)

          patient_list.flat_map do |patient_data|
            dfn = patient_data[:dfn]&.to_s
            next [] if dfn.blank?

            imms = begin
              lister.call(dfn)
            rescue => e
              data_errors << "Immunization data unavailable for patient #{PhiSanitizer.hash_identifier(dfn)}: #{e.class}"
              next []
            end
            next [] unless imms.is_a?(Array)

            imms.select { |imm| occ = imm[:occurrence_date]; occ.present? && date_range.cover?(occ) }
          end
        end

        def gather_lots(facility_ien: nil, data_errors: [], lot_lister: nil)
          lister = lot_lister || default_lot_lister
          lister.call(facility_ien: facility_ien)
        rescue => e
          data_errors << "Vaccine lot data unavailable: #{e.class}"
          []
        end

        def evaluate_compliance(immunizations, lot_index)
          flags = []

          immunizations.each do |imm|
            if imm[:vis_edition_date].blank? || imm[:vis_presentation_date].blank?
              missing = []
              missing << "edition date" if imm[:vis_edition_date].blank?
              missing << "presentation date" if imm[:vis_presentation_date].blank?
              flags << {
                type: "missing_vis",
                record_ien: imm[:ien],
                description: "Missing VIS #{missing.join(' and ')} for #{imm[:vaccine_display]}"
              }
            end

            lot = lot_index[imm[:lot_number]]
            if lot && lot[:expiration_date].present? && imm[:occurrence_date].present?
              if lot[:expiration_date] < imm[:occurrence_date]
                flags << {
                  type: "expired_lot",
                  record_ien: imm[:ien],
                  description: "Lot #{imm[:lot_number]} expired #{lot[:expiration_date]} before administration #{imm[:occurrence_date]}"
                }
              end
            end

            if imm[:funding_source] == "VFC"
              if imm[:vfc_eligibility_code].blank?
                flags << {
                  type: "vfc_eligibility_unknown",
                  record_ien: imm[:ien],
                  description: "VFC-funded vaccine administered without documented eligibility code"
                }
              elsif !VFC_ELIGIBLE_CODES.include?(imm[:vfc_eligibility_code])
                flags << {
                  type: "vfc_ineligible",
                  record_ien: imm[:ien],
                  description: "Patient with eligibility #{imm[:vfc_eligibility_code]} received VFC-funded vaccine"
                }
              end
            end
          end

          flags
        end

        def compute_statistics(immunizations)
          {
            total_immunizations: immunizations.length,
            vfc_count: immunizations.count { |i| i[:funding_source] == "VFC" },
            vfa_count: immunizations.count { |i| i[:funding_source] == "VFA" },
            with_vis: immunizations.count { |i| i[:vis_edition_date].present? && i[:vis_presentation_date].present? },
            without_vis: immunizations.count { |i| i[:vis_edition_date].blank? || i[:vis_presentation_date].blank? }
          }
        end

        def record_audit(agent_id, date_range, facility_ien)
          AuditEvent.create(
            event_type: "application",
            action: "E",
            outcome: "0",
            agent_who_identifier: agent_id,
            agent_who_type: "Practitioner",
            entity_type: "VfcComplianceReport",
            entity_id: "#{date_range.first}..#{date_range.last}",
            outcome_desc: "VFC compliance audit#{facility_ien.present? ? " for facility #{facility_ien}" : ""}"
          )
        rescue => e
          Rails.logger.error("VfcComplianceAuditService audit failed: #{e.message}")
        end

        def default_patient_searcher
          obj = Object.new
          obj.define_singleton_method(:call) { |*_args| Patient.search("") }
          obj
        end

        def default_immunization_lister
          obj = Object.new
          obj.define_singleton_method(:call) { |dfn| Immunization.list_for_patient(dfn) }
          obj
        end

        def default_lot_lister
          obj = Object.new
          obj.define_singleton_method(:call) { |**_args| [] }
          obj
        end
      end
    end
  end
end
