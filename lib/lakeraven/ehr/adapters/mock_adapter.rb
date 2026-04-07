# frozen_string_literal: true

require "securerandom"
require "lakeraven/ehr/adapters/base"

module Lakeraven
  module EHR
    module Adapters
      # In-memory adapter used by tests and Cucumber scenarios.
      #
      # Holds patients in a Ruby hash keyed by tenant_identifier so each
      # test can seed its own data without coordinating with anyone
      # else. Not thread-safe — there's no need; tests run serially
      # against a fresh instance.
      #
      # Per ADR 0002, this still doesn't store backend-native identifiers
      # in the result hashes returned to engine code. The patient_identifier
      # it returns is an opaque token (per ADR 0004), and the internal DFN
      # equivalent is held only inside the adapter.
      class MockAdapter < Base
        def initialize
          super
          # patients[tenant_identifier] => Array<Hash>
          @patients = Hash.new { |h, k| h[k] = [] }
        end

        # Test helper — adds a patient to the in-memory store. Mints
        # an opaque patient_identifier and returns it.
        def seed_patient(tenant_identifier:, facility_identifier:, display_name:, date_of_birth:, gender:)
          identifier = mint_patient_identifier
          record = {
            patient_identifier: identifier,
            tenant_identifier: tenant_identifier,
            facility_identifier: facility_identifier,
            display_name: display_name,
            date_of_birth: date_of_birth,
            gender: gender
          }
          @patients[tenant_identifier] << record
          identifier
        end

        def search_patients(tenant_identifier:, facility_identifier: nil, name: nil, identifier_system: nil, identifier_value: nil, date_of_birth: nil)
          rows = @patients[tenant_identifier]
          rows = rows.select { |r| r[:facility_identifier] == facility_identifier } if facility_identifier
          rows = rows.select { |r| r[:display_name].downcase.include?(name.downcase) } if name && !name.empty?
          rows = rows.select { |r| r[:date_of_birth] == coerce_date(date_of_birth) } if date_of_birth
          rows.map { |r| public_view(r) }
        end

        def find_patient(tenant_identifier:, patient_identifier:)
          row = @patients[tenant_identifier].find { |r| r[:patient_identifier] == patient_identifier }
          row ? public_view(row) : nil
        end

        private

        # Mints a prefixed token. Uses a UUIDv4 internally rather than a
        # full ULID; the test fixture doesn't need lex-sortability and
        # SecureRandom is in stdlib. Real adapters mint per ADR 0004.
        def mint_patient_identifier
          "pt_#{SecureRandom.uuid.delete('-')}"
        end

        # Strip internal-only keys before returning to caller. tenant_identifier
        # stays in because the caller already has it; the row needs to round-trip
        # cleanly through find_patient. No backend-native fields are exposed.
        def public_view(row)
          {
            patient_identifier: row[:patient_identifier],
            facility_identifier: row[:facility_identifier],
            display_name: row[:display_name],
            date_of_birth: row[:date_of_birth],
            gender: row[:gender]
          }
        end

        def coerce_date(value)
          return value if value.is_a?(Date)
          Date.parse(value.to_s)
        end
      end
    end
  end
end
