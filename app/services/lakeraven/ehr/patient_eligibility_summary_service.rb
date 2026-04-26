# frozen_string_literal: true

module Lakeraven
  module EHR
    # PatientEligibilitySummaryService - Aggregates eligibility data for patient display.
    # Read-only projection layer.
    class PatientEligibilitySummaryService
      Result = Struct.new(
        :prc_checks, :prc_eligible, :prc_denial_reason, :prc_checked_at,
        :coverage_summary, :coverage_retrieved_at,
        :payer_verification_results, :payer_verified_at, :payer_verification_skip_reason,
        keyword_init: true
      )

      PRC_CHECK_NAMES = %i[tribal_enrollment residency clinical_necessity payor_coordination].freeze

      class << self
        def summarize(patient:, service_request: nil)
          prc_result = check_prc(service_request) if service_request
          coverage = build_coverage_from_patient(patient)
          build_result(prc_result: prc_result, coverage: coverage, payer_verification: nil)
        end

        def refresh(patient:, service_request: nil, coverages: [])
          prc_result = check_prc(service_request) if service_request
          coverage = build_coverage_summary(coverages)
          payer_verification, skip_reason = check_payer_verification(patient: patient, coverages: coverages)
          build_result(prc_result: prc_result, coverage: coverage, payer_verification: payer_verification, payer_verification_skip_reason: skip_reason)
        end

        private

        def check_prc(service_request)
          EligibilityService.check(service_request)
        end

        def build_coverage_from_patient(patient)
          coverages = []
          if patient.coverage_type.present?
            coverages << Coverage.new(
              patient_dfn: patient.dfn.to_s,
              coverage_type: normalize_coverage_type(patient.coverage_type),
              status: "active"
            )
          end
          return nil if coverages.empty?
          CoverageSummaryService.new(coverages).summarize
        end

        def build_coverage_summary(coverages)
          return nil if coverages.empty?
          CoverageSummaryService.new(coverages).summarize
        end

        def check_payer_verification(patient:, coverages:)
          return [ nil, "No coverages available" ] if coverages.empty?

          verifiable = coverages.select { |c| c.subscriber_id.present? }
          if verifiable.empty?
            return [ nil, "No coverage has a subscriber ID for payer verification" ]
          end

          # Payer verification would call external service here
          [ nil, "Payer verification not configured" ]
        rescue => e
          Rails.logger.warn("Payer verification check failed: #{PhiSanitizer.sanitize_message(e.message)}")
          [ nil, "Payer verification is temporarily unavailable" ]
        end

        def build_result(prc_result:, coverage:, payer_verification:, payer_verification_skip_reason: nil)
          now = Time.current

          prc_checks = {}
          if prc_result
            PRC_CHECK_NAMES.each do |check_name|
              prc_checks[check_name] = {
                status: prc_result.check_status(check_name),
                message: prc_result.check_message(check_name)
              }
            end
          end

          Result.new(
            prc_checks: prc_checks,
            prc_eligible: prc_result&.eligible?,
            prc_denial_reason: prc_result&.denial_reason,
            prc_checked_at: prc_result ? now : nil,
            coverage_summary: coverage,
            coverage_retrieved_at: coverage ? now : nil,
            payer_verification_results: payer_verification || [],
            payer_verified_at: payer_verification&.any? ? now : nil,
            payer_verification_skip_reason: payer_verification_skip_reason
          )
        end

        def normalize_coverage_type(type)
          # Map rpms_redux coverage types to FHIR coverage types
          case type
          when "IHS" then "tribal_program"
          when /Medicare/i then "medicare_a"
          when /Medicaid/i then "medicaid"
          when /Private/i then "private_insurance"
          else "tribal_program"
          end
        end
      end
    end
  end
end
