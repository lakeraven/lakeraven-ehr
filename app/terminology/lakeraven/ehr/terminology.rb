# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # Base class for terminology serializers.
      # Pure transform — no I/O, no RPC calls, no database queries.
      # Projects a code value into a FHIR Coding using in-memory data.
      class Base
        attr_reader :code

        def initialize(code)
          @code = code.to_s.strip.presence
        end

        def system
          raise NotImplementedError, "#{self.class}#system"
        end

        def display
          @code
        end

        def status
          @code ? :mapped : :unmapped
        end

        def to_coding
          return { code: nil, system: system, display: nil } if status == :unmapped

          { code: code, system: system, display: display }.compact
        end
      end

      # ICD-10 — diagnosis codes
      # Editions: :cm (US), :se (Sweden), :ca (Canada), nil (international)
      class ICD10 < Base
        SYSTEMS = {
          cm: "http://hl7.org/fhir/sid/icd-10-cm",
          se: "http://hl7.org/fhir/sid/icd-10-se",
          ca: "http://hl7.org/fhir/sid/icd-10-ca",
          nil => "http://hl7.org/fhir/sid/icd-10"
        }.freeze

        def initialize(code, edition: :cm)
          super(code)
          @edition = edition
        end

        def system
          SYSTEMS[@edition] || SYSTEMS[:cm]
        end
      end

      # LOINC — observation/lab test identity (universal, no editions)
      class LOINC < Base
        def system
          "http://loinc.org"
        end
      end

      # RxNorm — US medication codes
      class RxNorm < Base
        def system
          "http://www.nlm.nih.gov/research/umls/rxnorm"
        end
      end

      # ATC — WHO Anatomical Therapeutic Chemical classification
      # Used in Sweden, international markets
      class ATC < Base
        def system
          "http://www.whocc.no/atc"
        end
      end

      # DIN — Health Canada Drug Identification Number
      class DIN < Base
        def system
          "https://health-products.canada.ca/dpd-bdpp"
        end
      end

      # SNOMED CT — clinical meaning (multi-edition)
      # Edition modules: US, Swedish, Canadian, international
      class SNOMED < Base
        EDITION_VERSIONS = {
          us: "http://snomed.info/sct/731000124108",
          se: "http://snomed.info/sct/45991000052106",
          ca: "http://snomed.info/sct/20611000087101",
          nil => nil
        }.freeze

        def initialize(code, edition: nil)
          super(code)
          @edition = edition
        end

        def system
          "http://snomed.info/sct"
        end

        def to_coding
          coding = super
          version = EDITION_VERSIONS[@edition]
          coding[:version] = version if version && status == :mapped
          coding
        end
      end
    end
  end
end
