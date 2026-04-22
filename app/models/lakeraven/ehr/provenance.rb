# frozen_string_literal: true

module Lakeraven
  module EHR
    class Provenance
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :target_type, :string
      attribute :target_id, :string
      attribute :recorded, :datetime
      attribute :activity, :string
      attribute :agent_who_id, :string
      attribute :agent_who_type, :string
      attribute :agent_type, :string

      def to_fhir
        {
          resourceType: "Provenance",
          target: [ { reference: "#{target_type}/#{target_id}" } ],
          recorded: recorded&.iso8601,
          activity: activity ? { text: activity } : nil,
          agent: [ {
            who: { reference: "#{agent_who_type}/#{agent_who_id}" }
          } ]
        }.compact
      end
    end
  end
end
