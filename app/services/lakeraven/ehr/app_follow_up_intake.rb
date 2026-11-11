# frozen_string_literal: true

module Lakeraven
  module EHR
    # Demo prototype (#988; not in the December build). Reads a FHIR
    # Communication a registered outside app posts about a referral into an
    # AppFollowUp held for review. Only one shape is taken:
    #
    #   subject  Patient/<dfn>
    #   about    exactly one ServiceRequest/<dfn>-<ien>, the id the FHIR read
    #            serves (FHIR::PatientScopedId), a referral of that patient
    #   sender   Device/<the token's client id>
    #   payload  exactly one contentString, at most 500 characters
    #   extension referral-follow-up: reached (boolean), appointmentDate (date)
    #
    # No attachment is taken (no audio, no transcript). Anything else is
    # refused with the reason, which the controller returns as an
    # OperationOutcome. Nothing is written to RPMS here.
    class AppFollowUpIntake
      Result = Struct.new(:follow_up, :error, keyword_init: true)

      def self.call(resource, application:, referrals_for:)
        new(resource, application, referrals_for).call
      end

      def initialize(resource, application, referrals_for)
        @resource = resource.is_a?(Hash) ? resource.deep_stringify_keys : {}
        @application = application
        @referrals_for = referrals_for
      end

      def call
        error = shape_error
        return Result.new(error: error) if error

        unless referral_of_patient?
          return Result.new(error: "ServiceRequest/#{referral_ien} is not a referral of Patient/#{patient_dfn}")
        end

        follow_up = AppFollowUp.new(
          client_id: @application.uid, app_name: @application.name, ai_generated: ai_generated?,
          patient_dfn: patient_dfn, referral_ien: referral_ien, status: "pending",
          reached: extension_value("reached", "valueBoolean"), appointment_on: appointment_on, summary: summary
        )
        follow_up.valid? ? Result.new(follow_up: follow_up) : Result.new(error: follow_up.errors.full_messages.join(", "))
      end

      private

      def shape_error
        return "resourceType must be Communication" unless @resource["resourceType"] == "Communication"
        return "subject must be Patient/<id>" unless patient_dfn
        return "about must be exactly one ServiceRequest/<id> of Patient/#{patient_dfn}" unless referral_ien
        return "sender must be Device/#{@application.uid}, the app this token was issued to" unless sender_is_app?
        return "payload must be exactly one contentString (no attachments: no audio, no transcript)" unless summary
        return "summary is longer than #{AppFollowUp::SUMMARY_LIMIT} characters" if summary.length > AppFollowUp::SUMMARY_LIMIT
        return "appointmentDate must be a date (YYYY-MM-DD)" if extension_value("appointmentDate", "valueDate") && appointment_on.nil?

        reached = extension_value("reached", "valueBoolean")
        "reached must be a boolean" unless reached.nil? || [ true, false ].include?(reached)
      end

      def patient_dfn
        @resource.dig("subject", "reference").to_s[%r{\APatient/(\d+)\z}, 1]&.to_i
      end

      def referral_ien
        about = Array(@resource["about"])
        return nil unless about.size == 1

        reference = about.first.is_a?(Hash) ? about.first["reference"].to_s : ""
        match = reference.match(%r{\AServiceRequest/(?<dfn>\d+)-(?<ien>\d+)\z})
        match && match[:dfn].to_i == patient_dfn ? match[:ien].to_i : nil
      end

      def sender_is_app?
        @resource.dig("sender", "reference") == "Device/#{@application.uid}"
      end

      def summary
        payload = Array(@resource["payload"])
        return nil unless payload.size == 1 && payload.first.is_a?(Hash) && payload.first.keys == [ "contentString" ]

        text = payload.first["contentString"]
        text.is_a?(String) && text.strip.present? ? text.strip : nil
      end

      def appointment_on
        value = extension_value("appointmentDate", "valueDate")
        value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(value) : nil
      rescue Date::Error
        nil
      end

      def extension_value(name, key)
        outer = Array(@resource["extension"]).find { |e| e.is_a?(Hash) && e["url"] == AppFollowUp::EXTENSION }
        inner = Array(outer && outer["extension"]).find { |e| e.is_a?(Hash) && e["url"] == name }
        inner && inner[key]
      end

      def ai_generated?
        Array(@resource.dig("meta", "tag")).any? { |t| t.is_a?(Hash) && t["code"] == AppFollowUp::AI_TAG[:code] }
      end

      def referral_of_patient?
        Array(@referrals_for.call(patient_dfn)).any? { |row| row[:ien].to_s == referral_ien.to_s }
      end
    end
  end
end
