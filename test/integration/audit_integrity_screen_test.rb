# frozen_string_literal: true

require "test_helper"

# The integrity screen is the artifact a compliance review reads. Two rules:
#
#   * It reports what is INSTALLED, never what the adapter could do (S1).
#   * It never claims tamper-evidence it does not have — an unkeyed digest
#     or an absent trigger is said loudly, not smoothed into a clean screen.
class AuditIntegrityScreenTest < ActionDispatch::IntegrationTest
  REVIEWER_KEY = "XUAUDIT REVIEW"

  setup { Lakeraven::EHR::AuditEvent.delete_all }
  teardown { Lakeraven::EHR.reset_configuration! }

  test "an anonymous visitor is redirected to sign in" do
    get "/lakeraven-ehr/audit-review/integrity"
    assert_response :redirect
  end

  test "with no reviewer key configured, everyone is refused — empty is not open" do
    sign_in_with_keys([ REVIEWER_KEY ])

    get "/lakeraven-ehr/audit-review/integrity"
    assert_response :forbidden
    assert_match(/not configured/i, response.body)
  end

  test "a signed-in user without the reviewer key is refused" do
    configure_reviewer_key
    sign_in_with_keys([ "SOME OTHER KEY" ])

    get "/lakeraven-ehr/audit-review/integrity"
    assert_response :forbidden
  end

  test "without a digest key the screen refuses to claim tamper-evidence" do
    configure_reviewer_key(digest_key: nil)
    sign_in_with_keys([ REVIEWER_KEY ])
    Lakeraven::EHR::AuditEvent.enforce_append_only!

    get "/lakeraven-ehr/audit-review/integrity"
    assert_response :ok
    assert_match(/NOT claimed/i, response.body)
    assert_match(/Do not cite this log as tamper-evident/i, response.body)
    assert_match(/unkeyed/i, response.body)
  end

  test "with an uninstalled trigger the screen says NOT INSTALLED, not 'for every client'" do
    configure_reviewer_key(digest_key: "test-only-key")
    sign_in_with_keys([ REVIEWER_KEY ])
    Lakeraven::EHR::AuditEvent.relax_append_only!

    get "/lakeraven-ehr/audit-review/integrity"
    assert_response :ok
    assert_match(/NOT INSTALLED/i, response.body)
    refute_match(/for every client/i, response.body,
      "the screen still overstates the enforcement's reach")
  ensure
    Lakeraven::EHR::AuditEvent.enforce_append_only!
  end

  test "with a key and an installed trigger the claim is made — with its limits stated" do
    configure_reviewer_key(digest_key: "test-only-key")
    sign_in_with_keys([ REVIEWER_KEY ])
    Lakeraven::EHR::AuditEvent.enforce_append_only!

    get "/lakeraven-ehr/audit-review/integrity"
    assert_response :ok
    assert_match(/Tamper-evidence/i, response.body)
    assert_match(/Claimed/, response.body)
    # S13: the trigger does not bind a table owner; the screen says so.
    assert_match(/DISABLE TRIGGER/i, response.body)
    assert_match(/TRUNCATE/i, response.body)
    refute_match(/for every client/i, response.body)
  end

  private

  def configure_reviewer_key(digest_key: :unset)
    Lakeraven::EHR.configure do |c|
      c.audit_review_security_keys = [ REVIEWER_KEY ]
      c.audit_digest_key = digest_key unless digest_key == :unset
    end
  end

  def sign_in_with_keys(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "99999", security_keys: keys }
    assert_response :ok
  end
end
