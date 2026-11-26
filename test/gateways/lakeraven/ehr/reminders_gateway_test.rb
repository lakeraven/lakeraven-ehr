# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RemindersGatewayTest < ActiveSupport::TestCase
      test "applicable returns empty array when no provider is available" do
        result = RemindersGateway.applicable(8791, 44, via: nil)
        assert_equal [], result
      end

      # The gateway asks rpms-rpc's Reminders.applicable for the patient at
      # the location, as strings, and hands back its rows: the engine's due
      # flag is already the row's status there.
      test "applicable reads the reminder engine for the patient at the location" do
        RpmsStandIn.answer(RpmsRpc::Reminders, :applicable, "8791", "44", with: [
          { id: 12, name: "Diabetic eye exam", status: :due, due_flag: 1, due_now: true, has_dialog: false },
          { id: 13, name: "Tobacco screen", status: :not_applicable, due_flag: 2, due_now: false, has_dialog: false }
        ])

        result = RemindersGateway.applicable(8791, 44)

        assert_equal [ %w[8791 44] ], RpmsStandIn.calls(RpmsRpc::Reminders, :applicable).map { |c| c[:args] }
        assert_equal [ [ "Diabetic eye exam", :due, true ], [ "Tobacco screen", :not_applicable, false ] ],
          result.map { |r| [ r[:name], r[:status], r[:due_now] ] }
      end

      test "default_provider resolves to RpmsRpc::Reminders" do
        assert_equal "RpmsRpc::Reminders", RemindersGateway.default_provider.name
      end
    end
  end
end
