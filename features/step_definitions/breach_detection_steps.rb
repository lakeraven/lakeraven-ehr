# frozen_string_literal: true

Given("{int} failed login attempts from IP {string} within {int} minutes") do |count, ip, _minutes|
  @failed_attempts ||= []
  count.times { @failed_attempts << { ip_address: ip, timestamp: Time.current } }
end

Given("the security monitor has already created an incident for IP {string}") do |ip|
  @monitor ||= Lakeraven::EHR::SecurityMonitor.new
  @monitor.run(failed_attempts: @failed_attempts)
  assert @monitor.incidents.any? { |i| i.ip_address == ip }
end

Given("more than {int} open brute_force security incidents exist") do |count|
  existing = (1..count + 1).map do |i|
    Lakeraven::EHR::SecurityIncident.new(
      ip_address: "10.99.99.#{i}", incident_type: "brute_force",
      severity: "high", status: "open"
    )
  end
  @monitor = Lakeraven::EHR::SecurityMonitor.new(incidents: existing)
end

When("the security monitor runs") do
  @monitor ||= Lakeraven::EHR::SecurityMonitor.new
  @monitor.run(failed_attempts: @failed_attempts || [])
end

When("the security monitor runs again") do
  @monitor.run(failed_attempts: @failed_attempts || [])
end

Then("a security incident should exist for IP {string}") do |ip|
  assert @monitor.incidents.any? { |i| i.ip_address == ip }
end

Then("the incident severity should be {string}") do |severity|
  assert @monitor.incidents.last.severity == severity
end

Then("the incident status should be {string}") do |status|
  assert @monitor.incidents.last.status == status
end

Then("there should be exactly {int} open incident(s) for IP {string}") do |count, ip|
  open_for_ip = @monitor.incidents.count { |i| i.ip_address == ip && i.open? }
  assert_equal count, open_for_ip
end

Then("running the security monitor should not create new brute_force incidents") do
  before_count = @monitor.incidents.length
  @monitor.run(failed_attempts: @failed_attempts || [])
  assert_equal before_count, @monitor.incidents.length
end
