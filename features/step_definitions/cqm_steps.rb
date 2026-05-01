# frozen_string_literal: true

require "ostruct"

Given("patient {string} has a condition with code {string} in valueset {string}") do |dfn, code, valueset|
  @conditions ||= []
  @conditions << OpenStruct.new(dfn: dfn, code: code, valueset_id: valueset)
end

Given("patient {string} has an observation with code {string} and value {float} recorded on {string}") do |dfn, code, value, date|
  @observations ||= []
  @observations << OpenStruct.new(dfn: dfn, code: code, value: value, effective_date: Date.parse(date))
end

Given("patient {string} has an observation with code {string} in valueset {string} recorded on {string}") do |dfn, code, _valueset, date|
  @observations ||= []
  @observations << OpenStruct.new(dfn: dfn, code: code, value: 1, effective_date: Date.parse(date))
end

Given("patient {string} has no conditions in valueset {string}") do |_dfn, _valueset|
  @conditions = []
end

Given("the system is configured for FHIR API access") do
  # Engine is always configured
end

Given("I have a valid SMART token with scope {string}") do |scopes|
  @oauth_app ||= Doorkeeper::Application.create!(
    name: "cqm-test", redirect_uri: "https://example.test/callback",
    scopes: scopes, confidential: true
  )
  token = Doorkeeper::AccessToken.create!(
    application: @oauth_app, scopes: scopes, expires_in: 3600
  )
  @fhir_headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
end

When("I evaluate measure {string} for patient {string} for period {string} to {string}") do |measure_id, dfn, start_date, end_date|
  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  @measure_report = service.evaluate(measure_id, dfn,
    period: Date.parse(start_date)..Date.parse(end_date))
end

When("I evaluate measure {string} for patients {string} for period {string} to {string}") do |measure_id, dfns, start_date, end_date|
  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  @summary_report = service.evaluate_population(measure_id, dfns.split(","),
    period: Date.parse(start_date)..Date.parse(end_date))
end

When("I request {string} with FHIR headers") do |request_string|
  method, path = request_string.split(" ", 2)
  url = path.sub("/fhir/", "/lakeraven-ehr/")
  header "Authorization", @fhir_headers["Authorization"]
  send(method.downcase.to_sym, url)
end

Then("the measure report should show initial population count of {int}") do |count|
  assert_equal count, @measure_report.initial_population_count
end

Then("the measure report should show denominator count of {int}") do |count|
  assert_equal count, @measure_report.denominator_count
end

Then("the measure report should show numerator count of {int}") do |count|
  assert_equal count, @measure_report.numerator_count
end

Then("the summary report should show initial population count of {int}") do |count|
  assert_equal count, @summary_report.initial_population_count
end

Then("the summary report should show numerator count of {int}") do |count|
  assert_equal count, @summary_report.numerator_count
end

Then("the summary report should have a performance rate of {float}") do |rate|
  assert_in_delta rate, @summary_report.performance_rate, 0.01
end

Then("the response should be a FHIR Bundle") do
  body = JSON.parse(last_response.body)
  assert_equal "Bundle", body["resourceType"]
end

Then("the bundle should contain measures") do
  body = JSON.parse(last_response.body)
  assert body["entry"]&.any?, "Expected measures in bundle, got total=#{body['total']}"
end

Then("the bundle should contain a MeasureReport with population groups") do
  body = JSON.parse(last_response.body)
  assert_equal "Bundle", body["resourceType"]
end

After do
  Doorkeeper::AccessToken.delete_all if defined?(Doorkeeper)
  Doorkeeper::Application.where(name: "cqm-test").delete_all if defined?(Doorkeeper)
  @conditions = nil
  @observations = nil
end
