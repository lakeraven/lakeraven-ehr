# frozen_string_literal: true

module Lakeraven
  module EHR
    # Part2Label -- the marker a record carries when it holds, or may hold,
    # 42 CFR Part 2 content (#906, slice of #522). One row per
    # (record_type, record_id). Identifiers and a security code only; never
    # clinical text.
    #
    # security_code is deliberately NOT validated against a vocabulary. A
    # row whose code this version does not recognise must still load and be
    # read, because Part2Posture counts ANY label row as Part 2 — an unknown
    # label is never a reason to treat a record as clean.
    class Part2Label < ApplicationRecord
      self.table_name = "lakeraven_ehr_part2_labels"

      PART2_SECURITY_CODE = "42CFRPart2"
      SECURITY_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ActCode"

      # record_type for a TIU progress note, keyed by its note IEN.
      TIU_NOTE = "tiu_note"

      validates :patient_dfn, :record_type, :record_id, :security_code, presence: true
      validates :record_id, uniqueness: { scope: :record_type }

      # Labels a record as Part 2. Idempotent: an existing row for the
      # record is left as it is (whatever its code) and counts as success.
      # Blank inputs raise ActiveRecord::RecordInvalid and write nothing.
      def self.mark!(patient_dfn:, record_type:, record_id:)
        attributes = { record_type: record_type.to_s, record_id: record_id.to_s }
        existing = find_by(attributes)
        return existing if existing

        create!(attributes.merge(patient_dfn: patient_dfn.to_s, security_code: PART2_SECURITY_CODE))
      rescue ActiveRecord::RecordNotUnique
        # A concurrent writer labelled the same record between the lookup
        # and the insert. The row exists, which is what was asked for.
        find_by!(attributes)
      end
    end
  end
end
