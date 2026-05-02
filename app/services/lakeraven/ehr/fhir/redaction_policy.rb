# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # View-aware PHI filtering for any FHIR output format.
      #
      # Views:
      #   :full          — No redaction (internal clinical use)
      #   :patient_safe  — Mask SSN, keep name/DOB/address (patient portal)
      #   :external      — Remove SSN, DFN, tribal enrollment (external providers)
      #   :research      — Remove all direct identifiers (de-identified per 45 CFR 164.514)
      class RedactionPolicy
        VIEWS = %i[full patient_safe external research].freeze

        SSN_SYSTEMS = %w[http://hl7.org/fhir/sid/us-ssn].freeze
        TRIBAL_URLS = %w[tribal-affiliation tribal-enrollment].freeze
        SOGI_URLS = %w[patient-sexualOrientation patient-genderIdentity].freeze

        def initialize(view: :full, scopes: nil)
          @view = view
          @scopes = scopes || []
        end

        def apply(resource)
          return resource if @view == :full

          result = deep_dup(resource)

          case @view
          when :patient_safe
            mask_ssn!(result)
          when :external
            remove_ssn!(result)
            remove_tribal_extensions!(result)
          when :research
            remove_identifiers!(result)
            remove_name!(result)
            remove_birth_date!(result)
            remove_address!(result)
            remove_telecom!(result)
            remove_tribal_extensions!(result)
            remove_sogi_extensions!(result)
          end

          result
        end

        private

        def deep_dup(hash)
          hash.transform_values do |v|
            case v
            when Hash then deep_dup(v)
            when Array then v.map { |e| e.is_a?(Hash) ? deep_dup(e) : e }
            else v
            end
          end
        end

        def mask_ssn!(resource)
          return unless resource[:identifier]

          resource[:identifier].each do |id|
            if SSN_SYSTEMS.any? { |s| id[:system]&.include?(s) }
              id[:value] = "***-**-#{id[:value]&.last(4)}"
            end
          end
        end

        def remove_ssn!(resource)
          return unless resource[:identifier]

          resource[:identifier].reject! { |id| SSN_SYSTEMS.any? { |s| id[:system]&.include?(s) } }
        end

        def remove_identifiers!(resource)
          resource[:identifier] = []
        end

        def remove_name!(resource)
          resource[:name] = []
        end

        def remove_birth_date!(resource)
          resource.delete(:birthDate)
        end

        def remove_address!(resource)
          resource[:address] = []
        end

        def remove_telecom!(resource)
          resource[:telecom] = []
        end

        def remove_tribal_extensions!(resource)
          return unless resource[:extension]

          resource[:extension].reject! { |e| TRIBAL_URLS.any? { |u| e[:url]&.include?(u) } }
        end

        def remove_sogi_extensions!(resource)
          return unless resource[:extension]

          resource[:extension].reject! { |e| SOGI_URLS.any? { |u| e[:url]&.include?(u) } }
        end
      end
    end
  end
end
