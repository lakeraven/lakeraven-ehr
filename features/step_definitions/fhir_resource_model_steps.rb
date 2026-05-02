# frozen_string_literal: true

# Shared step definitions for Organization, Location, PractitionerRole FHIR resources

# --- Shared FHIR assertions ---

Then("the FHIR subject reference should include {string}") do |id|
  subject = @fhir[:subject]
  refute_nil subject, "Expected subject in FHIR output"
  assert_includes subject[:reference], id
end

# --- Organization ---

Given("an organization with name {string}") do |name|
  @organization = Lakeraven::EHR::Organization.new(ien: 1, name: name)
end

Given("an organization without a name") do
  @organization = Lakeraven::EHR::Organization.new(ien: 1)
end

Given("an organization with name {string} and station number {string}") do |name, station|
  @organization = Lakeraven::EHR::Organization.new(ien: 1, name: name, station_number: station)
end

When("I serialize the organization to FHIR") do
  @fhir = @organization.to_fhir
end

Then("the organization should be valid") do
  assert @organization.valid?, "Expected valid: #{@organization.errors.full_messages}"
end

Then("the organization should be invalid") do
  refute @organization.valid?
end

Then("the station number should be {string}") do |station|
  assert_equal station, @organization.station_number
end

Then("the FHIR organization name should be {string}") do |name|
  assert_equal name, @fhir[:name]
end

Then("the FHIR identifiers should include station number {string}") do |station|
  ids = @fhir[:identifier] || []
  assert ids.any? { |i| i[:value] == station }, "Expected station number #{station} in identifiers"
end

# --- Location ---

Given("a location with name {string}") do |name|
  @location = Lakeraven::EHR::Location.new(ien: 1, name: name)
end

Given("a location without a name") do
  @location = Lakeraven::EHR::Location.new(ien: 1)
end

Given("a location with name {string} and abbreviation {string}") do |name, abbr|
  @location = Lakeraven::EHR::Location.new(ien: 1, name: name, abbreviation: abbr)
end

Given("a location with name {string} and status {string}") do |name, status|
  @location = Lakeraven::EHR::Location.new(ien: 1, name: name, status: status)
end

When("I serialize the location to FHIR") do
  @fhir = @location.to_fhir
end

Then("the location should be valid") do
  assert @location.valid?, "Expected valid: #{@location.errors.full_messages}"
end

Then("the location should be invalid") do
  refute @location.valid?
end

Then("the abbreviation should be {string}") do |abbr|
  assert_equal abbr, @location.abbreviation
end

Then("the FHIR location name should be {string}") do |name|
  assert_equal name, @fhir[:name]
end

Then("the FHIR location status should be {string}") do |status|
  assert_equal status, @fhir[:status]
end

# --- PractitionerRole ---

Given("a practitioner role with role {string} for practitioner {string}") do |role, ien|
  @practitioner_role = Lakeraven::EHR::PractitionerRole.new(
    practitioner_ien: ien.to_i, organization_ien: 1, role: role, active: true
  )
end

Given("a practitioner role with specialty {string} for practitioner {string}") do |specialty, ien|
  @practitioner_role = Lakeraven::EHR::PractitionerRole.new(
    practitioner_ien: ien.to_i, organization_ien: 1, role: "doctor", specialty: specialty, active: true
  )
end

Given("an active practitioner role for practitioner {string}") do |ien|
  @practitioner_role = Lakeraven::EHR::PractitionerRole.new(
    practitioner_ien: ien.to_i, organization_ien: 1, role: "doctor", active: true
  )
end

When("I serialize the practitioner role to FHIR") do
  @fhir = @practitioner_role.to_fhir
end

Then("the practitioner role should be valid") do
  assert @practitioner_role.valid?, "Expected valid: #{@practitioner_role.errors.full_messages}"
end

Then("the specialty should be {string}") do |specialty|
  assert_equal specialty, @practitioner_role.specialty
end

Then("the practitioner role should be active") do
  assert @practitioner_role.active?, "Expected active"
end

Then("the FHIR practitioner reference should include {string}") do |ien|
  pract = @fhir[:practitioner]
  refute_nil pract
  assert_includes pract[:reference], ien
end

Then("the FHIR specialty should include {string}") do |text|
  specs = @fhir[:specialty]
  refute_nil specs
  assert specs.any? { |s| s[:text]&.include?(text) || s[:coding]&.any? { |c| c[:display]&.include?(text) } }
end
