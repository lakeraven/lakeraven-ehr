# frozen_string_literal: true

module Lakeraven
  module EHR
    # Validates a FHIR R4 ServiceRequest and stores it on the local intake
    # queue. Idempotent per OAuth client and Identifier: the same identifiers
    # replay the original row, and identifiers that span two rows conflict.
    # Nothing here calls RPMS.
    class InboundReferralIntake
      Result = Data.define(:status, :referral, :diagnostics) do
        def self.created(referral) = new(status: :created, referral: referral, diagnostics: [])
        def self.replayed(referral) = new(status: :replayed, referral: referral, diagnostics: [])
        def self.conflict = new(status: :conflict, referral: nil, diagnostics: [ "ServiceRequest.identifier" ])
        def self.invalid(diagnostics) = new(status: :invalid, referral: nil, diagnostics: diagnostics)
      end

      # FHIR R4 RequestIntent. Intake accepts only draft and active, which is
      # narrower than RequestStatus.
      REQUEST_INTENTS = %w[
        proposal plan directive order original-order reflex-order filler-order instance-order option
      ].freeze
      ACCEPTED_STATUSES = %w[draft active].freeze

      def self.call(resource, application)
        new(resource, application).call
      end

      def initialize(resource, application)
        @resource = resource.deep_stringify_keys
        @application = application
      end

      def call
        problems = validation_problems
        return Result.invalid(problems) if problems.any?

        persist
      rescue ActiveRecord::RecordNotUnique
        replay_after_race
      end

      private

      attr_reader :resource, :application

      def persist
        # Own savepoint. AuditableClinicalAccess already holds a transaction;
        # a unique violation must roll back only this insert so the retry and
        # the audit row can still commit.
        ActiveRecord::Base.transaction(requires_new: true) { resolve }
      end

      def resolve
        ids = matching_referral_ids
        return Result.replayed(load_referral(ids.first)) if ids.one?
        return Result.conflict if ids.many?

        Result.created(insert_referral)
      end

      def replay_after_race
        ids = matching_referral_ids
        return Result.replayed(load_referral(ids.first)) if ids.one?

        Result.conflict
      end

      def load_referral(id)
        InboundReferral.find(id)
      end

      def insert_referral
        referral = InboundReferral.create!(referral_attributes)
        identifier_pairs.each { |system, value| insert_identifier(referral, system, value) }
        referral
      end

      def referral_attributes
        {
          oauth_application_id: application.id,
          organization_id: application.organization_id,
          status: InboundReferral::RECEIVED,
          patient_identifier_system: subject_identifier["system"],
          patient_identifier_value: subject_identifier["value"],
          resource: stored_resource
        }
      end

      def insert_identifier(referral, system, value)
        referral.identifiers.create!(
          oauth_application_id: application.id,
          system: system,
          value: value
        )
      end

      def stored_resource
        resource.except("id", "meta")
      end

      def subject_identifier
        resource.dig("subject", "identifier") || {}
      end

      def identifier_pairs
        @identifier_pairs ||= Array(resource["identifier"]).filter_map { |entry|
          next unless entry.is_a?(Hash)

          [ entry["system"], entry["value"] ]
        }.uniq
      end

      def matching_referral_ids
        pairs = identifier_pairs
        return [] if pairs.empty?

        pairs.map { |system, value| identifiers_for(system, value) }
             .reduce(:or)
             .distinct
             .pluck(:inbound_referral_id)
      end

      def identifiers_for(system, value)
        InboundReferralIdentifier.where(
          oauth_application_id: application.id,
          system: system,
          value: value
        )
      end

      def validation_problems
        [
          resource_type_problem,
          *element_problem("status", ACCEPTED_STATUSES),
          *element_problem("intent", REQUEST_INTENTS),
          *identifier_problems,
          *subject_problems,
          *code_problems
        ].compact
      end

      def resource_type_problem
        "resourceType" unless resource["resourceType"] == "ServiceRequest"
      end

      def element_problem(name, allowed)
        "ServiceRequest.#{name}" unless allowed.include?(resource[name])
      end

      def identifier_problems
        entries = resource["identifier"]
        return [ "ServiceRequest.identifier" ] unless entries.is_a?(Array) && entries.any?

        entries.each_with_index.flat_map { |entry, index| identifier_entry_problems(entry, index) }
      end

      def identifier_entry_problems(entry, index)
        prefix = "ServiceRequest.identifier[#{index}]"
        return [ prefix ] unless entry.is_a?(Hash)

        [ "#{prefix}.system", "#{prefix}.value" ].reject { |path| present_string?(entry[path.split(".").last]) }
      end

      def subject_problems
        subject = resource["subject"]
        return [ "ServiceRequest.subject" ] unless subject.is_a?(Hash)

        identifier = subject["identifier"]
        return [ "ServiceRequest.subject.identifier" ] unless identifier.is_a?(Hash)

        problems = []
        problems << "ServiceRequest.subject.identifier.system" unless present_string?(identifier["system"])
        problems << "ServiceRequest.subject.identifier.value" unless present_string?(identifier["value"])
        problems
      end

      def code_problems
        code = resource["code"]
        return [ "ServiceRequest.code" ] unless code.is_a?(Hash)
        return [] if present_string?(code["text"]) || code["coding"].is_a?(Array) && code["coding"].any?

        [ "ServiceRequest.code" ]
      end

      def present_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
