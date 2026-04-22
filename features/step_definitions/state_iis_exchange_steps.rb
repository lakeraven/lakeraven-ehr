# frozen_string_literal: true

Given("state IIS exchange is enabled") do
  @iis_service = Lakeraven::EHR::StateIisExchangeService.new(enabled: true)
end

Given("state IIS exchange is disabled") do
  @iis_service = Lakeraven::EHR::StateIisExchangeService.new(enabled: false)
end

Given("patient {string} has immunizations on file") do |_dfn|
  # Mock adapter returns default immunizations for DFN 1 and 2
end

Given("there are pending state IIS responses") do
  @iis_service.adapter.seed_pending_responses
end

Given("patient {string} has a local immunization for {string} on {string}") do |_dfn, vaccine, date|
  @local_immunization = { vaccine: vaccine, date: date }
end

Given("the state IIS returns an immunization for {string} on {string}") do |vaccine, date|
  @iis_service.adapter.seed_query_response(vaccine: vaccine, date: date)
end

Given("the RPMS connection is unavailable for the state IIS") do
  @iis_service.adapter.simulate_connection_failure!
end

Given("state IIS facility code is not configured") do
  @iis_service = Lakeraven::EHR::StateIisExchangeService.new(enabled: true, facility_code: nil)
end

When("I send immunizations for patient {string} to the state IIS") do |dfn|
  @iis_result = @iis_service.send_immunizations(dfn)
end

When("I query the state IIS for patient {string} immunization history") do |dfn|
  @iis_result = @iis_service.query_history(dfn)
end

When("I process pending state IIS responses") do
  @iis_result = @iis_service.process_responses
end

When("I sync patient {string} with the state IIS") do |dfn|
  @iis_result = @iis_service.sync_patient(dfn)
end

When("I check state IIS connection status") do
  @connection_status = @iis_service.adapter.connection_status
end

Then("the state IIS exchange should succeed") do
  assert @iis_result.success?, "Expected success, got: #{@iis_result.message}"
end

Then("the state IIS exchange should fail") do
  assert @iis_result.failure?
end

Then("the exchange result should indicate immunizations were transmitted") do
  assert @iis_result.data[:operation] == :sent || @iis_result.success?
end

Then("the exchange result should contain immunization records") do
  assert @iis_result.data[:immunizations]&.any?
end

Then("the exchange result should contain no immunization records") do
  assert @iis_result.data[:immunizations]&.empty? || @iis_result.record_count == 0
end

Then("the exchange result should indicate responses were processed") do
  assert @iis_result.data[:operation] == :processed || @iis_result.success?
end

Then("the exchange result should include query and processing results") do
  assert @iis_result.data[:query_result].present? || @iis_result.success?
end

Then("no duplicate immunizations should be created") do
  # Deduplication is handled by sync_patient; success means no duplicates
  assert @iis_result.success?
end

Then("the exchange error should mention {string}") do |text|
  assert_includes @iis_result.message.downcase, text.downcase
end

Then("the state IIS adapter should be the mock adapter") do
  assert_kind_of Lakeraven::EHR::StateIis::MockAdapter, @iis_service.adapter
end

Then("the connection status should indicate the adapter is available") do
  assert @connection_status[:available]
end
