# frozen_string_literal: true

require "test_helper"

# F3's second half (round-2 gate on #512, external seat): the failure row is
# written after the wrapper's own rollback, but a CALLER-OWNED parent
# transaction — a service, an importer, a harness owning its transaction —
# still rolls back when the re-raised exception aborts it, and a plain
# insert would join it and vanish. The raising access truly happened; its
# record survives on a connection of its own.
#
# Transactional tests are OFF, deliberately: the wrapper pins a
# thread-locked connection and the detached write degrades to inline there
# (see AuditEvent.create_detached!), so a wrapped version of this test
# proves nothing. This one exercises the real second-connection path and
# cleans up its own rows.
class AuditFailureRowSurvivalTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup { Lakeraven::EHR::AuditEvent.delete_all }

  teardown do
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::ReconciliationSession.where(source_type: "test").delete_all
    @application&.destroy
  end

  test "the failure row survives a caller-owned transaction's rollback" do
    setup_auth(scopes: "system/*.read system/*.write")
    before = Lakeraven::EHR::ReconciliationSession.count

    assert_raises(AuditedWriterController::SyntheticActionFailure) do
      ActiveRecord::Base.transaction do
        post "/audited_writer", params: { patient_dfn: "1", explode: "1" }, headers: @headers
      end
    end

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "the failure row joined the caller's transaction and vanished with it"
    assert_equal "8", event.outcome
    assert_match(/SyntheticActionFailure/, event.outcome_desc.to_s)
    assert_equal before, Lakeraven::EHR::ReconciliationSession.count,
      "the raising action's write survived the rollback"
  end

  private

  def setup_auth(scopes:)
    @application = Doorkeeper::Application.create!(
      name: "client-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @application, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
