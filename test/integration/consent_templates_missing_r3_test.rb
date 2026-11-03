# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

class ConsentTemplatesMissingR3Test < ActionDispatch::IntegrationTest
  include ConsentWriteTestHelper

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Lakeraven::EHR::AuditEvent.delete_all
    @demo_original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    sign_in_clinician!(scopes: WRITE_SCOPES)
    open_patient_context!(DFN)
    Lakeraven::EHR::ConsentTemplate.delete_all
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "GET consents new states why handover is unavailable when no templates are installed" do
    get "#{BASE}/new"

    assert_response :ok
    assert_match(/template|install|unavailable|not.*installed/i, response.body,
                 "expected a stated reason, not an empty picker")
    assert_select "form[action=?][method=post]", HANDOVER do
      assert_select "button[type=submit], input[type=submit]", count: 0
    end
  end

  test "POST handover with no templates installed answers 404 with that reason" do
    post_handover(template_key: TEMPLATE_BH)

    assert_response :not_found
    assert_match(/template|install|unavailable|not.*installed/i, response.body)
    assert_equal 0, Lakeraven::EHR::KioskLock.count
  end
end
