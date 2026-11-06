# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to put a patient on a wait list, or to change
    # their entry (rpms-ux S-SCH-10.1, 10.2, 10.4). Comments are not here: no
    # RPC can file them (rpms-ops#1083).
    class WaitListAddition
      include ActiveModel::Model
      include ActiveModel::Attributes

      # #9009017.11 .02 PRIORITY.
      PRIORITIES = { "1" => "High", "2" => "Middle", "3" => "Low" }.freeze

      attribute :patient_dfn, :integer
      attribute :added_on, :date
      attribute :reason_ien, :integer
      attribute :priority, :string
      attribute :provider_ien, :integer
      attribute :recall_on, :date

      validates :patient_dfn, presence: { message: "is required: choose a patient" }, on: :add
      validates :added_on, presence: { message: "is required" }, on: :add
      validates :reason_ien, presence: { message: "is required" }
      validates :recall_on, presence: { message: "is required" }
      validates :priority, inclusion: { in: PRIORITIES.keys }, allow_blank: true

      # What RPMS holds on an entry (a RpmsRpc::WaitList row), for the edit form.
      def self.from_entry(entry)
        new(reason_ien: entry[:reason_ien], priority: entry[:priority], provider_ien: entry[:provider_ien], recall_on: entry[:recall_on])
      end

      def add_attrs
        { patient_dfn: patient_dfn, added_on: added_on, reason: reason_ien, recall_on: recall_on,
          priority: priority.presence, provider: provider_ien }
      end

      def edit_attrs
        { reason: reason_ien, recall_on: recall_on, priority: priority.presence, provider: provider_ien }
      end
    end
  end
end
