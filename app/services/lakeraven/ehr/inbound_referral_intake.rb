# frozen_string_literal: true

module Lakeraven
  module EHR
    # Validates a FHIR R4 ServiceRequest and stores it on the local intake
    # queue. Idempotent per OAuth client and Identifier: the same identifiers
    # and the same subject replay the original row. Identifiers that span two
    # rows, or one row with a different subject, conflict. Nothing here calls RPMS.
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
      # Bytes, not characters. The unique btree index on
      # (oauth_application_id, system, value) holds about 2704 bytes, and
      # UTF-8 can exceed that inside a character limit.
      MAX_IDENTIFIER_VALUE_BYTES = 255
      MAX_IDENTIFIER_SYSTEM_BYTES = 1024
      NUL_BYTE = "\u0000"
      # Fixed text only. A path would copy client keys and indexes into the
      # OperationOutcome, and those are submitted text.
      NUL_DIAGNOSTIC = "ServiceRequest (string contains NUL)"
      private_constant :NUL_BYTE, :NUL_DIAGNOSTIC

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
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked
        # The savepoint already rolled back. One more lookup, outside it.
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
        replay_or_conflict(matching_referral_ids) || Result.created(insert_referral)
      end

      def replay_after_race
        replay_or_conflict(matching_referral_ids) || Result.conflict
      end

      # One match with the same subject is a replay. Several matches, or one
      # match whose subject differs, conflict. Nothing matches returns nil.
      def replay_or_conflict(ids)
        return Result.conflict if ids.many?
        return unless ids.one?

        referral = load_referral(ids.first)
        same_subject?(referral) ? Result.replayed(referral) : Result.conflict
      end

      def same_subject?(referral)
        referral.patient_identifier_system == subject_identifier["system"] &&
          referral.patient_identifier_value == subject_identifier["value"]
      end

      def load_referral(id)
        InboundReferral.find(id)
      end

      def insert_referral
        referral = InboundReferral.create!(referral_attributes)
        # system, then value, so concurrent inserts lock the unique index in one order.
        identifier_pairs.sort.each { |system, value| insert_identifier(referral, system, value) }
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
          *code_problems,
          *nul_byte_problems
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

        bounded_identifier_problems(entry, prefix)
      end

      def subject_problems
        subject = resource["subject"]
        return [ "ServiceRequest.subject" ] unless subject.is_a?(Hash)

        identifier = subject["identifier"]
        return [ "ServiceRequest.subject.identifier" ] unless identifier.is_a?(Hash)

        bounded_identifier_problems(identifier, "ServiceRequest.subject.identifier")
      end

      def bounded_identifier_problems(entry, prefix)
        [
          *bounded_string_problem(entry["system"], "#{prefix}.system", MAX_IDENTIFIER_SYSTEM_BYTES),
          *bounded_string_problem(entry["value"], "#{prefix}.value", MAX_IDENTIFIER_VALUE_BYTES)
        ]
      end

      def bounded_string_problem(value, path, max_bytes)
        return path unless present_string?(value)
        return path if value.bytesize > max_bytes

        nil
      end

      def code_problems
        code = resource["code"]
        return [ "ServiceRequest.code" ] unless code.is_a?(Hash)
        return [] if present_string?(code["text"]) || usable_coding?(code["coding"])

        [ "ServiceRequest.code" ]
      end

      def usable_coding?(coding)
        coding.is_a?(Array) && coding.any? { |entry| coding_code?(entry) }
      end

      def coding_code?(entry)
        entry.is_a?(Hash) && present_string?(entry["code"])
      end

      def present_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def nul_byte_problems
        return [] unless nul_byte_in?(resource)

        [ NUL_DIAGNOSTIC ]
      end

      def nul_byte_in?(node)
        case node
        when String
          node.include?(NUL_BYTE)
        when Array
          node.any? { |child| nul_byte_in?(child) }
        when Hash
          nul_byte_in_hash?(node)
        else
          false
        end
      end

      def nul_byte_in_hash?(node)
        node.any? { |key, child| key.to_s.include?(NUL_BYTE) || nul_byte_in?(child) }
      end
    end
  end
end
