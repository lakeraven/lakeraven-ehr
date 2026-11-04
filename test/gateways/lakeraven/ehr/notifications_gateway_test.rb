# frozen_string_literal: true

require "test_helper"

# NotificationsGateway reads the signed-in user's alerts through the gem's
# BEHOXQ ALRLIST read (rpms-ux S-SGN-02.1), on the rows a rpms-ydb e9b78c8
# container answered on 2026-11-04 (test/integration/notifications_test.rb).
module Lakeraven
  module EHR
    class NotificationsGatewayTest < ActiveSupport::TestCase
      CAPTURED = [
        "1^0^^  ^Staff meeting moved to 3 PM.^3261104.175352^MANAGER,SYSTEM^0^BEHOXQ^BEHOXQ,PROBE;4;3261104.175352^0^PRI=1^INF=0",
        "2^1^MOUSE,MICKEY M    (1001)^  ^Unscheduled visit.^3261104.174742^POSTMASTER^3^OR.19^OR,3,19;.5;3261104.174742^1^",
        "2^1^MOUSE,MICKEY M    (1001)^  ^Unscheduled visit (probe).^3261104.175206^MANAGER,SYSTEM^3^OR.19^OR,3,19;4;3261104.175206^1^"
      ].freeze

      setup { RpmsRpc.client.seed_raw_lines(:notifications_inbox, "", CAPTURED) }
      teardown { RpmsRpc.client.seed_raw_lines(:notifications_inbox, "", []) }

      test "inbox lists the user's alerts newest first, asking RPMS for no user" do
        alerts = NotificationsGateway.inbox

        assert_equal [ "BEHOXQ,PROBE;4;3261104.175352", "OR,3,19;4;3261104.175206", "OR,3,19;.5;3261104.174742" ],
          alerts.map { |a| a[:alert_id] }
        call = RpmsRpc.client.received_calls.reverse.find { |c| c[:rpc] == "BEHOXQ ALRLIST" }
        assert_empty call[:params].to_a, "ALRLIST answers for the session's own user"
      end
    end
  end
end
