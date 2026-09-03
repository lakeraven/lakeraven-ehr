# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes a FHIR R4 Provenance for an Observation, distinguishing
      # office-measured values from values captured outside an in-person
      # clinical visit (Vardana source-system profile §3/§7 item 10).
      #
      # RPMS/PCC grounding — the distinction is the source system's own:
      # a V MEASUREMENT (file 9000010.01, ^AUPNVMSR) points at its VISIT
      # (file 9000010, ^AUPNVSIT) via field .03, and the visit's SERVICE
      # CATEGORY (field .07) records the encounter's capture MODALITY:
      #
      #   A Ambulatory / H Hospitalization / I In Hospital / O Observation /
      #   S Day Surgery / R Nursing Home / D Daily Hospitalization Data
      #     → in-person clinical capture: agent.type = author, who = the
      #       recording provider (display name when the read supplies one).
      #
      #   T Telecommunications / M Telemedicine / E Event (Historical) /
      #   C Chart Review
      #     → NOT office-measured. The DD records the capture modality, NOT
      #       an informant: a chart-review or telemedicine encounter says
      #       nothing about WHO supplied the value, so no agent.type and no
      #       who=Patient reference is asserted. The agent carries an honest
      #       display ("not office-measured — source modality: X;
      #       informant not recorded") and Provenance.activity carries the
      #       raw service-category code for machine consumption.
      #
      #   anything else / absent → NO Provenance — Vardana treats a value
      #   without provenance as unverified (§3), the honest degrade.
      #
      # R4 shape notes: agent.type is 0..1 CodeableConcept (NOT an array);
      # `recorded` is the instant this provenance statement was recorded
      # (i.e. when this server derived it), while the observation's clinical
      # time rides `occurredDateTime`.
      class ObservationProvenanceSerializer
        OFFICE_CATEGORIES   = %w[A H I O S R D].freeze
        REPORTED_CATEGORIES = %w[T M E C].freeze

        PARTICIPANT_TYPE_SYSTEM = "http://terminology.hl7.org/CodeSystem/provenance-participant-type"

        # Local code system carrying the raw PCC visit SERVICE CATEGORY —
        # the wire-proven fact, exposed as-is for machine consumption.
        SERVICE_CATEGORY_SYSTEM = "https://lakeraven.com/fhir/CodeSystem/rpms-visit-service-category"

        MODALITY_DISPLAY = {
          "T" => "Telecommunications",
          "M" => "Telemedicine",
          "E" => "Event (Historical)",
          "C" => "Chart Review"
        }.freeze

        def self.call(observation, recorded_at: Time.current)
          new(observation, recorded_at: recorded_at).to_h
        end

        # Deterministic Provenance id for an Observation id — stable across
        # reads (Vardana §5.3) and reversible for target search.
        def self.id_for(observation_id)
          "prov-#{observation_id}"
        end

        def initialize(observation, recorded_at: Time.current)
          @o = observation
          @recorded_at = recorded_at
        end

        def to_h
          agent = build_agent
          return nil if agent.nil? || @o.ien.blank?

          {
            resourceType: "Provenance",
            id: self.class.id_for(@o.ien),
            target: [ { reference: "Observation/#{@o.ien}" } ],
            occurredDateTime: @o.effective_datetime&.iso8601,
            recorded: @recorded_at.iso8601,
            activity: build_activity,
            agent: [ agent ]
          }.compact
        end

        private

        def category
          @o.service_category.to_s.strip.upcase
        end

        def build_agent
          case category
          when *OFFICE_CATEGORIES   then office_agent
          when *REPORTED_CATEGORIES then reported_agent
          end
        end

        # R4 Provenance.agent.type is a single CodeableConcept (0..1).
        def office_agent
          {
            type: participant_type("author", "Author"),
            who: office_who
          }
        end

        # The recording provider when the measurement read carries one
        # (BGOVMSR GET reply piece 6, the encounter provider name) — a
        # display reference, never an invented resource id.
        def office_who
          if @o.provider_name.present?
            { display: @o.provider_name }
          else
            { display: "Recording facility (in-person clinical visit)" }
          end
        end

        # The source establishes only the capture modality — no informant.
        # agent.type is omitted (0..1) rather than asserting a participant
        # role the wire cannot prove; who is mandatory (1..1), so it carries
        # the honest display.
        def reported_agent
          modality = MODALITY_DISPLAY.fetch(category, category)
          {
            who: { display: "Not office-measured — source modality: #{modality}; informant not recorded" }
          }
        end

        def build_activity
          {
            coding: [ {
              system: SERVICE_CATEGORY_SYSTEM,
              code: category,
              display: activity_display
            }.compact ]
          }
        end

        def activity_display
          return MODALITY_DISPLAY[category] if MODALITY_DISPLAY.key?(category)

          "In-person clinical capture" if OFFICE_CATEGORIES.include?(category)
        end

        def participant_type(code, display)
          { coding: [ { system: PARTICIPANT_TYPE_SYSTEM, code: code, display: display } ] }
        end
      end
    end
  end
end
