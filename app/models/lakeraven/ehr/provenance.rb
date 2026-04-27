# frozen_string_literal: true

module Lakeraven
  module EHR
    class Provenance
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_ACTIVITIES = %w[CREATE UPDATE DELETE].freeze
      ACTIVITY_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-DataOperation"

      attribute :target_type, :string
      attribute :target_id, :string
      attribute :recorded, :datetime
      attribute :activity, :string
      attribute :agent_who_id, :string
      attribute :agent_who_type, :string
      attribute :agent_type, :string

      # Entity tracking (derivation/revision)
      attribute :entity_role, :string
      attribute :entity_what_type, :string
      attribute :entity_what_id, :string

      validates :target_type, presence: true
      validates :target_id, presence: true
      validates :agent_who_id, presence: true
      validates :activity, inclusion: { in: VALID_ACTIVITIES }, allow_nil: true

      def initialize(attributes = {})
        super
        self.recorded ||= Time.current
      end

      # -- Activity predicates -----------------------------------------------

      def create? = activity == "CREATE"
      def update? = activity == "UPDATE"
      def delete? = activity == "DELETE"

      def activity_display
        activity&.capitalize
      end

      # -- Agent type --------------------------------------------------------

      def agent_type_display
        agent_type&.capitalize
      end

      # -- Entity ------------------------------------------------------------

      def has_entity?
        entity_what_id.present? && entity_what_type.present?
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        resource = {
          resourceType: "Provenance",
          target: [{ reference: "#{target_type}/#{target_id}" }],
          recorded: recorded&.iso8601,
          activity: build_activity,
          agent: [build_agent]
        }.compact

        resource[:entity] = build_entity if has_entity?

        resource
      end

      private

      def build_activity
        return nil unless activity

        {
          coding: [{ system: ACTIVITY_SYSTEM, code: activity, display: activity_display }]
        }
      end

      def build_agent
        agent = {
          who: { reference: "#{agent_who_type}/#{agent_who_id}" }
        }
        if agent_type.present?
          agent[:type] = [{ coding: [{ code: agent_type }] }]
        end
        agent
      end

      def build_entity
        [{
          role: entity_role,
          what: { reference: "#{entity_what_type}/#{entity_what_id}" }
        }]
      end
    end
  end
end
