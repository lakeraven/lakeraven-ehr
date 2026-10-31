# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RemindersGatewayTest < ActiveSupport::TestCase
      test "applicable returns empty array when no provider is available" do
        result = RemindersGateway.applicable(8791, 44, via: nil)
        assert_equal [], result
      end

      # Through the gem's own Reminders.applicable and the ORQQPXRM REMINDERS
      # APPLICABLE mapping: the frame carries the patient and the location,
      # and the engine's due flag becomes the row's status.
      test "applicable reads the reminder engine for the patient at the location" do
        RpmsRpc.client.seed_keyed_collection(:reminders_applicable, "8791", [
          { ien: 12, print_name: "Diabetic eye exam", due_flag: 1, due_date: "DUE NOW" },
          { ien: 13, print_name: "Tobacco screen", due_flag: 2, due_date: "" }
        ])

        result = RemindersGateway.applicable(8791, 44)

        assert_equal [ %w[8791 44] ], RpmsRpc.client.received_calls
          .select { |c| c[:rpc] == "ORQQPXRM REMINDERS APPLICABLE" }.map { |c| c[:params] }
        assert_equal [ [ "Diabetic eye exam", :due, true ], [ "Tobacco screen", :not_applicable, false ] ],
          result.map { |r| [ r[:name], r[:status], r[:due_now] ] }
      end

      test "default_provider resolves to RpmsRpc::Reminders" do
        assert_equal "RpmsRpc::Reminders", RemindersGateway.default_provider.name
      end
    end
  end
end
