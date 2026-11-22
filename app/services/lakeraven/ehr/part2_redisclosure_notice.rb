# frozen_string_literal: true

module Lakeraven
  module EHR
    # The 42 CFR § 2.32 redisclosure notice and the labels that call for it.
    # Part2EgressFilter puts the notice on every Part 2-labelled resource
    # that leaves through the egress seam.
    module Part2RedisclosureNotice
      # 42 CFR § 2.32(a)(1), as amended by the 2024 final rule.
      TEXT = "This record which has been disclosed to you is protected by Federal confidentiality rules " \
        "(42 CFR part 2). These rules prohibit you from using or disclosing this record, or testimony that " \
        "describes the information contained in this record, in any civil, criminal, administrative, or " \
        "legislative proceedings by any Federal, State, or local authority, against the patient, unless " \
        "authorized by the consent of the patient, except as provided at 42 CFR 2.12(c)(5) or as authorized " \
        "by a court in accordance with 42 CFR 2.64 or 2.65. In addition, the Federal rules prohibit you from " \
        "making any other use or disclosure of this record unless at least one of the following applies: " \
        "(i) Further use or disclosure is expressly permitted by the written consent of the individual whose " \
        "information is being disclosed in this record or as otherwise permitted by 42 CFR part 2. (ii) You " \
        "are a covered entity or business associate and have received the record for treatment, payment, or " \
        "health care operations, or (iii) You have received the record from a covered entity or business " \
        "associate as permitted by 45 CFR part 164, subparts A and E. A general authorization for the release " \
        "of medical or other information is NOT sufficient to meet the required elements of written consent " \
        "to further use or redisclose the record (see 42 CFR 2.31)."

      EXTENSION_URL = "https://lakeraven.com/fhir/StructureDefinition/part2-redisclosure-notice"

      # HL7 refrain policy: no redisclosure without a consent directive.
      REFRAIN = { "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code" => "NORDSCLCD" }.freeze

      # Privacy law 42CFRPart2 and the v3-ActCode substance-use sensitivity
      # codes (ETHUD alcohol, OPIOIDUD opioid). A sensitivity label alone
      # counts as Part 2 (fail closed). Matched stripped and without case.
      PART2_CODES = %w[42CFRPart2 ETH SUD ETHUD OPIOIDUD].freeze

      EXTENSION = { "url" => EXTENSION_URL, "valueString" => TEXT }.freeze

      PADDING = /\A[[:space:]\p{Cf}]+|[[:space:]\p{Cf}]+\z/

      def self.part2_code?(code)
        value = code.to_s.gsub(PADDING, "")
        PART2_CODES.any? { |part2| part2.casecmp?(value) }
      end

      # The fields an ingested item carries for its labels ({ system:, code: }
      # Hashes): the labels de-duplicated on system and code, and whether any
      # of them is a Part 2 code. Labels are a marker, never a block.
      def self.label_fields(labels)
        unique = labels.uniq { |label| label.values_at(:system, :code) }
        { security_labels: unique, part2: unique.any? { |label| part2_code?(label[:code]) } }
      end
    end
  end
end
