# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The demo charting surface accumulates the provider's entries in the
    # SESSION so the page renders them back — vitals, POV narrative, and the
    # free-text note. That is exactly the state a refused (unrecorded) access
    # must not carry out (S8's twin on #507): the fail-closed audit core
    # rolls the whole session back, and this surface backs it with its own
    # rollback hook so the leak is closed however the core's generic rollback
    # evolves.
    #
    # The demo 404s outside development, so these drive it the way the demo
    # bypass test does — toggling the environment for the duration.
    class DemoVisitsAuditTest < ActionController::TestCase
      tests DemoVisitsController

      # Synthetic; the point is that it must NOT survive an unrecorded access.
      NOTE_PHI = "Anderson,Alice — chief complaint follows"

      setup do
        @routes = Lakeraven::EHR::Engine.routes
        @original_env = Rails.env
        Rails.env = "development"
        ENV["CHART_DEMO_OPEN"] = "1"
        ENV["SPIKE_MOCK_RPC"] = "1"
        AuditEvent.delete_all
      end

      teardown do
        Rails.env = @original_env
        ENV.delete("CHART_DEMO_OPEN")
        ENV.delete("SPIKE_MOCK_RPC")
      end

      test "the walk-in note text lands in the session (the state at risk)" do
        post :note, params: { dfn: "1", note_text: NOTE_PHI }

        assert_equal NOTE_PHI, session[:demo_visits]["1"]["note"]["text"],
          "the demo did not stash the note in the session — the test's premise is stale"
      end

      test "an unrecorded demo access purges the session-held visit PHI" do
        post :note, params: { dfn: "1", note_text: NOTE_PHI }
        assert_equal NOTE_PHI, session[:demo_visits]["1"]["note"]["text"]

        # The hook the fail-closed core calls when it refuses an unrecorded
        # access. Its only implementer must be this controller.
        @controller.send(:rollback_unrecorded_access)

        refute_includes session.to_hash.to_s, NOTE_PHI,
          "a refused demo access left the note text in the session"
        assert_nil session[:demo_visits],
          "the in-progress visit survived an unrecorded access"
      end

      test "a demo write is audited under the demo service actor, never a session human" do
        # Even if some other surface had signed a browser session in, the
        # demo action is the demo's, not that human's.
        session[:duz] = "99999"

        post :vitals, params: { dfn: "1", vitals: { "TMP" => "98.9" } }

        event = AuditEvent.order(:id).last
        refute_nil event, "the demo write left no audit trail"
        assert_equal "Patient", event.entity_type
        assert_equal "1", event.entity_identifier
        refute_equal "99999", event.agent_who_identifier,
          "the demo action was filed under a bystanding browser session"
      end
    end
  end
end
