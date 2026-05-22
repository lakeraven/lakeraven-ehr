# frozen_string_literal: true

# FakeVitalGateway — scenario-scoped, captures calls, returns a fixed
# success result by default. Passed into VitalsEntryService via the
# constructor so production VitalGateway is never touched.
class FakeVitalGateway
  attr_reader :calls

  def initialize(return_value = { success: true, raw: "0" })
    @return_value = return_value
    @calls = []
  end

  def add(*args, **kwargs)
    @calls << { args: args, kwargs: kwargs }
    @return_value
  end
end

Given("an open encounter {string} at location {int}") do |visit_string, location_ien|
  @visit_string = visit_string
  @location_ien = location_ien
  @vital_gateway = FakeVitalGateway.new
end

When("the provider enters the following vitals:") do |table|
  measurements = table.hashes.map do |row|
    { abbreviation: row["abbreviation"], value: row["value"], units: row["units"] }
  end
  @vitals_result = Lakeraven::EHR::VitalsEntryService.new(
    dfn: @dfn,
    visit_string: @visit_string,
    measurements: measurements,
    provider_duz: 2843,
    gateway: @vital_gateway
  ).save
end

When("the provider enters no vitals") do
  @vitals_result = Lakeraven::EHR::VitalsEntryService.new(
    dfn: @dfn,
    visit_string: @visit_string,
    measurements: [],
    provider_duz: 2843,
    gateway: @vital_gateway
  ).save
end

When("the provider enters the following vitals without a visit context:") do |table|
  measurements = table.hashes.map do |row|
    { abbreviation: row["abbreviation"], value: row["value"], units: row["units"] }
  end
  @vitals_result = Lakeraven::EHR::VitalsEntryService.new(
    dfn: @dfn,
    visit_string: nil,
    measurements: measurements,
    provider_duz: 2843,
    gateway: @vital_gateway
  ).save
end

Then("the vitals save should succeed") do
  assert @vitals_result.success?, "Expected success; got #{@vitals_result.error.inspect}"
end

Then("the vitals save should fail with {symbol}") do |error_symbol|
  refute @vitals_result.success?
  assert_equal error_symbol, @vitals_result.error
end

Then("{int} measurements should be recorded") do |count|
  assert_equal count, @vitals_result.measurements.length
end

Then("the gateway should receive a save with {int} measurements") do |count|
  call = @vital_gateway.calls.first
  refute_nil call
  assert_equal count, call[:args][2].length
end
