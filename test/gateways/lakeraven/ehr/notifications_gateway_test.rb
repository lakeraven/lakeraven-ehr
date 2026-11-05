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

      # ORWU NEWPERS as the container answered PROFILE,MD's search for
      # "PROFILE" on 2026-11-04: a page of the name index starting there, so
      # it runs past the names that start with the text.
      NEWPERS_PROFILE = [
        "204^Profile,Ma^- MEDICAL ASSISTANT", "206^Profile,Md^- PHYSICIAN", "207^Profile,Reg^- PAT REG.",
        "205^Profile,Rn^- NURSE", "208^Profile,Sched^- MEDICAL SCHEDULER", "200^Provider,Test"
      ].freeze

      test "recipients are the users whose names start with the text, without the user themself" do
        RpmsRpc.client.seed_raw_lines(:user_management_user_list, "PROFILE", NEWPERS_PROFILE)

        assert_equal %w[Profile,Ma Profile,Reg Profile,Rn Profile,Sched],
          NotificationsGateway.recipients("Profile", except: "206").map { |r| r[:name] }, "not Provider,Test, past the text"
        call = RpmsRpc.client.received_calls.reverse.find { |c| c[:rpc] == "ORWU NEWPERS" }
        assert_equal [ "PROFILE", "1" ], call[:params].to_a, "searched as typed, upper case, forward"
      ensure
        RpmsRpc.client.seed_raw_lines(:user_management_user_list, "PROFILE", [])
      end

      test "a blank search asks RPMS nothing" do
        RpmsRpc.client.received_calls.clear
        assert_equal [], NotificationsGateway.recipients("  ")
        assert_empty RpmsRpc.client.received_calls.select { |c| c[:rpc] == "ORWU NEWPERS" }
      end
    end
  end
end
