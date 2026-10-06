# frozen_string_literal: true

ORHC_SITE_IEN = 5001

Before("@orhc_platform") do
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
end

After("@orhc_platform") do
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
end

Given("the ORHC platform test patient is seeded") do
  client = RpmsRpc.client
  client.seed(:patient_select, "9101", {
    name: "Kessler,Pat", sex: "F", dob: Date.parse("1959-04-12"),
    ssn: "900-00-9101", age: 67
  })
  client.seed(:patient_id_info, "9101", {
    ssn: "900-00-9101", dob: Date.parse("1959-04-12"), sex: "F",
    race_code: "I", site_ien: ORHC_SITE_IEN, name: "Kessler,Pat"
  })
end

Given("I hold an org-bound SMART token for site {int}") do |site_ien|
  app = Doorkeeper::Application.create!(
    name: "orhc-platform-gate", redirect_uri: "https://example.test/callback",
    scopes: "system/Patient.read", confidential: true,
    organization_id: "rpms-organization-#{site_ien}"
  )
  token = Doorkeeper::AccessToken.create!(
    application: app, scopes: "system/Patient.read", expires_in: 3600
  )
  @orhc_headers = {
    "Authorization" => "Bearer #{token.plaintext_token || token.token}"
  }
end

When("I GET {string}") do |path|
  header "Authorization", @orhc_headers["Authorization"]
  get path
  @orhc_response_body = JSON.parse(last_response.body)
rescue
  @orhc_response_body = nil
end

When("I GET {string} with X-Request-Id {string}") do |path, request_id|
  header "Authorization", @orhc_headers["Authorization"]
  header "X-Request-Id", request_id
  get path
  @orhc_response_body = JSON.parse(last_response.body)
rescue
  @orhc_response_body = nil
end

# "the response status should be {int}" is defined once, in
# bulk_export_steps.rb. Cucumber step definitions are global, so redefining it
# here made every status assertion in features/partner_backend_services_auth.feature
# an Ambiguous match — silently turning the cross-organization denial gate that
# CI runs as a merge check into 53 failing scenarios that asserted nothing.

Then("the response should echo X-Request-Id {string}") do |request_id|
  assert_equal request_id, last_response.headers["X-Request-Id"],
    "inbound correlation id must be echoed for booth screen capture"
end

Then("the response should include a generated X-Request-Id") do
  generated = last_response.headers["X-Request-Id"]
  refute generated.blank?, "must generate X-Request-Id when absent"
  assert_match(/\A[0-9a-f-]{36}\z/i, generated)
end

Then("the Patient resource should carry HTEST security meta") do
  meta = @orhc_response_body["meta"]
  refute_nil meta
  htest = Array(meta["security"]).find { |c|
    c["code"] == "HTEST" &&
      c["system"] == "http://terminology.hl7.org/CodeSystem/v3-ActReason"
  }
  refute_nil htest, "missing meta.security HTEST"
  refute Array(meta["tag"]).any? { |t| t["code"] == "orhc-2026-demo" },
    "per-resource meta.tag must not be stamped"
  assert meta["profile"].present?, "meta.profile must remain"
end
