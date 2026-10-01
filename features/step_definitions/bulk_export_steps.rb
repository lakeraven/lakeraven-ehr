# frozen_string_literal: true

When("I request GET {string} without a Bearer token") do |path|
  url = path.sub("/fhir/", "/lakeraven-ehr/")
  get url
end

When("I request DELETE {string} without a Bearer token") do |path|
  url = path.sub("/fhir/", "/lakeraven-ehr/")
  delete url
end

When("I request GET {string} with the Bearer token") do |path|
  url = path.sub("/fhir/", "/lakeraven-ehr/")
  header "Authorization", @fhir_headers["Authorization"]
  get url
end

Given("a bulk export exists for a different client") do
  other_app = Doorkeeper::Application.create!(
    name: "other-client", redirect_uri: "https://other.test/callback",
    scopes: "system/*.read", confidential: true
  )
  @other_export_id = "other-export-1"
  @other_client_uid = other_app.uid

  # The export must ACTUALLY EXIST and be owned by the other client.
  # Creating only the application left ExportsController.store empty, so
  # find_owned_export returned nil and the request 404'd because the export
  # was MISSING -- which the scenario would have passed even if foreign
  # exports were fully readable. The whole point is to distinguish
  # "exists but not yours" from "does not exist", since ExportOwnership
  # deliberately makes them identical on the wire.
  Lakeraven::EHR::ExportsController.store[@other_export_id] =
    Lakeraven::EHR::BulkExport.new(
      id: @other_export_id,
      export_type: "patient",
      status: "completed",
      client_id: other_app.uid
    )
end

After do
  Lakeraven::EHR::ExportsController.store.delete(@other_export_id) if @other_export_id
end

When("I check the status of the other client's export with my Bearer token") do
  header "Authorization", @fhir_headers["Authorization"]
  # Route corrected: $export-status was never routed; status is GET exports/:id.
  get "/lakeraven-ehr/exports/#{@other_export_id}"
end

Then("the response status should be {int}") do |status|
  assert_equal status, last_response.status, "Expected #{status}, got #{last_response.status}: #{last_response.body[0..200]}"
end

Then("the response should be a FHIR OperationOutcome with code {string}") do |code|
  body = JSON.parse(last_response.body)
  assert_equal "OperationOutcome", body["resourceType"]
  assert_equal code, body["issue"]&.first&.dig("code")
end

Then("the response should contain {string}") do |text|
  assert_includes last_response.body.downcase, text.downcase
end

After do
  Doorkeeper::AccessToken.delete_all if defined?(Doorkeeper)
  Doorkeeper::Application.where(name: %w[fhir-test other-client bulk-test]).delete_all if defined?(Doorkeeper)
end
