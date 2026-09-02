# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes a FHIR R4 Provenance (US Core shape: target, recorded,
      # agent) for an Observation, distinguishing office-measured from
      # patient-reported values (Vardana source-system profile §3/§7 item 10).
      #
      # RPMS/PCC grounding — the distinction is the source system's own:
      # a V MEASUREMENT (file 9000010.01, ^AUPNVMSR) points at its VISIT
      # (file 9000010, ^AUPNVSIT) via node-0 piece 3, and the visit's
      # SERVICE CATEGORY (field .07, node-0 piece 7 — see
      # $$SCAT^AZAXCADU / ^DD(9000010,.07)) records how the encounter's
      # data was captured:
      #
      #   A  Ambulatory          \
      #   H  Hospitalization      |
      #   I  In Hospital          |  in-person clinical capture
      #   O  Observation          |  -> agent.type "author",
      #   S  Day Surgery         /      who = recording clinician/facility
      #
      #   T  Telecommunications  \
      #   M  Telemedicine         |  reported, not measured in the office
      #   E  Event (Historical)   |  -> agent.type "informant",
      #   C  Chart Review        /      who = Patient
      #
      # An observation with no service category yields NO Provenance —
      # Vardana treats a value without provenance as unverified (§3), which
      # is the honest representation of the current ORQQVI VITALS read path
      # (TYPE^VALUE^UNITS^DATE carries no visit context; the gateway supplies
      # service_category only where a PCC visit read is available).
      class ObservationProvenanceSerializer
        OFFICE_CATEGORIES   = %w[A H I O S].freeze
        REPORTED_CATEGORIES = %w[T M E C].freeze

        PARTICIPANT_TYPE_SYSTEM = "http://terminology.hl7.org/CodeSystem/provenance-participant-type"

        def self.call(observation)
          new(observation).to_h
        end

        # Deterministic Provenance id for an Observation id — stable across
        # reads (Vardana §5.3) and reversible for target search.
        def self.id_for(observation_id)
          "prov-#{observation_id}"
        end

        def initialize(observation)
          @o = observation
        end

        def to_h
          agent = build_agent
          return nil if agent.nil? || @o.ien.blank?

          {
            resourceType: "Provenance",
            id: self.class.id_for(@o.ien),
            target: [ { reference: "Observation/#{@o.ien}" } ],
            recorded: @o.effective_datetime&.iso8601,
            agent: [ agent ]
          }.compact
        end

        private

        def build_agent
          case @o.service_category.to_s.upcase
          when *OFFICE_CATEGORIES   then office_agent
          when *REPORTED_CATEGORIES then informant_agent
          end
        end

        def office_agent
          {
            type: [ participant_type("author", "Author") ],
            who: office_who
          }
        end

        # The recording clinician when the row carries one (V MEASUREMENT
        # node-12 piece 4, the entered-by DUZ); otherwise a display-only
        # reference — never an invented resource id.
        def office_who
          if @o.provider_duz.present?
            { reference: "Practitioner/#{@o.provider_duz}" }
          else
            { display: "Recording facility (in-person clinical visit)" }
          end
        end

        def informant_agent
          {
            type: [ participant_type("informant", "Informant") ],
            who: { reference: "Patient/#{@o.patient_dfn}" }
          }
        end

        def participant_type(code, display)
          { coding: [ { system: PARTICIPANT_TYPE_SYSTEM, code: code, display: display } ] }
        end
      end
    end
  end
end
