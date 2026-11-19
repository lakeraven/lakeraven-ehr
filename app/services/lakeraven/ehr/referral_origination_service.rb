# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates referral creation from the EHR side.
    # Validates the ServiceRequest and optionally pre-checks enrollment
    # as clinical context for the ordering clinician.
    #
    # Enrollment pre-check is informational — it does not block the referral.
    # If corvid is present, corvid enforces enrollment via the eligibility
    # checklist. EHR-only customers still benefit from seeing enrollment
    # status at point of referral.
    #
    # The EHR does NOT call corvid directly — it returns an origination result
    # that the host app uses to create the PrcReferral via corvid's adapter.
    class ReferralOriginationService
      OriginationResult = Struct.new(
        :success, :service_request, :patient_identifier,
        :enrollment_status, :errors,
        keyword_init: true
      ) do
        def success? = success
      end

      def initialize(enrollment_checker: nil)
        @enrollment_checker = enrollment_checker
      end

      def originate(patient_dfn:, provider_ien:, params:)
        refusal = refusal_for(params)
        return OriginationResult.new(success: false, service_request: nil, errors: [ refusal ]) if refusal

        sr = ServiceRequest.new(
          patient_dfn: patient_dfn.to_i,
          requesting_provider_ien: provider_ien.to_i,
          service_requested: field(params, :service_requested),
          urgency: field(params, :urgency),
          reason_for_referral: field(params, :reason_for_referral),
          status: "draft"
        )

        unless sr.valid?
          return OriginationResult.new(
            success: false, errors: sr.errors.full_messages
          )
        end

        OriginationResult.new(
          success: true,
          service_request: sr,
          patient_identifier: patient_dfn.to_s,
          enrollment_status: check_enrollment(patient_dfn),
          errors: []
        )
      end

      private

      # #905: fail closed on anything but plain text under the declared
      # origination fields. Keys are read without to_h/permit so unpermitted
      # Parameters work too. Values are never inspected beyond their type.
      def refusal_for(params)
        return if params.nil?
        return refusal_text("params are not a set of named fields") unless hash_like?(params)

        accepted = ReferralSurfaces::ORIGINATION_FIELDS.map(&:to_s)
        names = params.keys.map(&:to_s)
        problems = names.tally.map do |name, count|
          if count > 1 then [ name, "ambiguous" ]
          elsif !accepted.include?(name) then [ name, "not accepted" ]
          elsif !text_or_nil?(field(params, name.to_sym)) then [ name, "not text" ]
          end
        end.compact
        refusal_message(problems) if problems.any?
      end

      # A refused key is echoed only when it is a ServiceRequest attribute
      # name; every other key is counted, never echoed.
      def refusal_message(problems)
        shown, hidden = problems.partition { |name, _| ServiceRequest.attribute_names.include?(name) }
        refused = shown.map { |name, why| "#{name} (#{why})" }
        refused << "#{hidden.size} other key(s)" if hidden.any?
        refusal_text("refused: #{refused.join(', ')}")
      end

      def refusal_text(reason)
        "Structured referral types are not offered; origination accepts only " \
          "#{ReferralSurfaces::ORIGINATION_FIELDS.join(', ')} as text; #{reason}"
      end

      def hash_like?(params)
        params.is_a?(Hash) || params.is_a?(ActionController::Parameters)
      end

      def text_or_nil?(value)
        value.nil? || value.is_a?(String)
      end

      # Reads a value only for a key actually present, so a Hash default or
      # default proc never supplies one.
      def field(params, name)
        return nil if params.nil?

        [ name.to_sym, name.to_s ].each { |key| return params[key] if params.key?(key) }
        nil
      end

      def check_enrollment(patient_dfn)
        return nil unless @enrollment_checker

        result = @enrollment_checker.call(patient_dfn)
        { verified: result[:enrolled] || false, tribe_name: result[:tribe_name] }
      rescue
        nil
      end
    end
  end
end
