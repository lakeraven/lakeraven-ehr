# frozen_string_literal: true

# FHIR SMART Authentication Steps — lakeraven-ehr
# Only defines steps not already in cqm_steps.rb or bulk_export_steps.rb.

When("I request GET {string} with the Bearer token and params:") do |path, table|
  params = table.rows_hash
  (@fhir_headers || {}).each { |k, v| header k, v }
  get "#{path}?#{URI.encode_www_form(params)}"
end

Then("the response status should not be {int}") do |status|
  refute_equal status, last_response.status,
    "Expected response status to NOT be #{status}"
end
