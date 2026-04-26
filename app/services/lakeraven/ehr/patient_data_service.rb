# frozen_string_literal: true

module Lakeraven
  module EHR
    # PatientDataService - Unified patient data access with PHR-first strategy.
    class PatientDataService
      attr_reader :dfn, :data_source

      def initialize(dfn)
        @dfn = dfn.to_s
        @data_source = nil
        @phr_available = nil
      end

      def medications
        if phr_available?
          fetch_via_phr(:medications) || fetch_medications_direct
        else
          fetch_medications_direct
        end
      end

      def lab_results(days: 90)
        if phr_available?
          fetch_via_phr(:labs) || fetch_lab_results_direct(days: days)
        else
          fetch_lab_results_direct(days: days)
        end
      end

      def allergies
        if phr_available?
          fetch_via_phr(:allergies) || fetch_allergies_direct
        else
          fetch_allergies_direct
        end
      end

      def vitals
        if phr_available?
          fetch_via_phr(:vitals) || fetch_vitals_direct
        else
          fetch_vitals_direct
        end
      end

      def immunizations
        if phr_available?
          fetch_via_phr(:immunizations) || fetch_immunizations_direct
        else
          fetch_immunizations_direct
        end
      end

      def health_summary(type: "PATIENT")
        return nil unless phr_available?
        HealthSummary.generate(dfn, summary_type: type)
      end

      def ccds(start_date: 1.year.ago.to_date, end_date: Date.current)
        return [] unless phr_available?
        Phr.ccds(dfn, start_date: start_date, end_date: end_date)
      end

      def clinical_reminders
        if phr_available?
          HealthSummary.clinical_reminders(dfn)
        else
          fetch_reminders_direct
        end
      end

      def phr_available?
        return @phr_available unless @phr_available.nil?
        @phr_available = check_phr_availability
      end

      private

      def fetch_via_phr(component)
        result = HealthSummary.component_data(dfn, component)
        if result && result[:content].present?
          @data_source = :phr
          parse_component_content(component, result[:content])
        else
          nil
        end
      rescue => e
        Rails.logger.debug("PHR fetch failed for #{component}, falling back to direct: #{e.message}")
        nil
      end

      def parse_component_content(component, content)
        case component
        when :medications then parse_medications_text(content)
        when :labs then parse_labs_text(content)
        when :allergies then parse_allergies_text(content)
        when :vitals then parse_vitals_text(content)
        when :immunizations then parse_immunizations_text(content)
        else content
        end
      end

      def fetch_medications_direct
        @data_source = :direct
        MedicationRequest.for_patient(dfn)
      rescue => e
        Rails.logger.warn("Direct medication fetch failed: #{e.message}")
        []
      end

      def fetch_lab_results_direct(days: 90)
        @data_source = :direct
        DiagnosticReport.recent_labs(dfn, days: days)
      rescue => e
        Rails.logger.warn("Direct lab fetch failed: #{e.message}")
        []
      end

      def fetch_allergies_direct
        @data_source = :direct
        patient = Patient.find_by_dfn(dfn)
        patient&.allergies || []
      rescue => e
        Rails.logger.warn("Direct allergy fetch failed: #{e.message}")
        []
      end

      def fetch_vitals_direct
        @data_source = :direct
        patient = Patient.find_by_dfn(dfn)
        patient&.vitals || {}
      rescue => e
        Rails.logger.warn("Direct vitals fetch failed: #{e.message}")
        {}
      end

      def fetch_immunizations_direct
        @data_source = :direct
        Immunization.list_for_patient(dfn)
      rescue => e
        Rails.logger.warn("Direct immunizations fetch failed: #{e.message}")
        []
      end

      def fetch_reminders_direct
        @data_source = :direct
        []
      rescue => e
        Rails.logger.warn("Direct reminders fetch failed: #{e.message}")
        []
      end

      def check_phr_availability
        return false if phr_disabled_by_config?
        # Check PHR connectivity
        false
      rescue => e
        Rails.logger.info("PHR not available: #{PhiSanitizer.sanitize_message(e.message)}")
        false
      end

      def phr_disabled_by_config?
        ENV["RPMS_PHR_ENABLED"] == "false" || ENV["RPMS_PHR_DISABLED"] == "true"
      end

      def parse_medications_text(content)
        meds = []
        content.to_s.split("\n").each do |line|
          next if line.blank? || line.match?(/^[-=]+$/)
          if line.match?(/\d+\s*mg|\d+\s*mcg|tablet|capsule|daily|bid|tid|qid/i)
            meds << { raw: line.strip, source: :phr }
          end
        end
        meds
      end

      def parse_labs_text(content)
        labs = []
        content.to_s.split("\n").each do |line|
          next if line.blank? || line.match?(/^[-=]+$/)
          labs << { raw: line.strip, source: :phr }
        end
        labs
      end

      def parse_allergies_text(content)
        allergies = []
        content.to_s.split("\n").each do |line|
          next if line.blank? || line.match?(/^[-=]+$/)
          if line.include?("-")
            parts = line.split("-", 2)
            allergies << { allergen: parts[0].strip, reaction: parts[1]&.strip, source: :phr }
          else
            allergies << { allergen: line.strip, source: :phr }
          end
        end
        allergies
      end

      def parse_vitals_text(content)
        vitals = []
        content.to_s.split("\n").each do |line|
          next if line.blank? || line.match?(/^[-=]+$/)
          if line.include?(":")
            parts = line.split(":", 2)
            vitals << { type: parts[0].strip, value: parts[1]&.strip, source: :phr }
          end
        end
        vitals
      end

      def parse_immunizations_text(content)
        immunizations = []
        content.to_s.split("\n").each do |line|
          next if line.blank? || line.match?(/^[-=]+$/)
          immunizations << { raw: line.strip, source: :phr }
        end
        immunizations
      end
    end
  end
end
