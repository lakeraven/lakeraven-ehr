# frozen_string_literal: true

# ValueSet audit service step definitions

Given("a ValueSet audit service") do
  @vs_audit = Lakeraven::EHR::ValueSetAuditService.new
end

When("I record access to ValueSet {string} by agent {string}") do |vs_id, agent_id|
  @vs_audit.record_access(vs_id, agent_id: agent_id)
end

When("I record expansion of ValueSet {string} by agent {string} with {int} codes") do |vs_id, agent_id, count|
  @last_provenance = @vs_audit.record_expansion(vs_id, agent_id: agent_id, code_count: count)
end

When("I record expansion of ValueSet {string} by agent {string} with {int} codes cached") do |vs_id, agent_id, count|
  @last_provenance = @vs_audit.record_expansion(vs_id, agent_id: agent_id, code_count: count, cached: true)
end

When("I record validation of code {string} against ValueSet {string} by agent {string} with result true") do |code, vs_id, agent_id|
  @vs_audit.record_validation(vs_id, code: code, agent_id: agent_id, result: true)
end

When("I record creation of ValueSet {string} by agent {string}") do |vs_id, agent_id|
  @vs_audit.record_create(vs_id, agent_id: agent_id)
end

When("I record creation of ValueSet {string} by agent {string} from source {string}") do |vs_id, agent_id, source|
  @vs_audit.record_create(vs_id, agent_id: agent_id, source: source)
end

When("I record update of ValueSet {string} by agent {string}") do |vs_id, agent_id|
  @vs_audit.record_update(vs_id, agent_id: agent_id)
end

When("I record deletion of ValueSet {string} by agent {string}") do |vs_id, agent_id|
  @vs_audit.record_delete(vs_id, agent_id: agent_id)
end

Then("the audit history for {string} should have {int} entry/entries") do |vs_id, count|
  history = @vs_audit.history(vs_id)
  assert_equal count, history.length, "Expected #{count} entries, got #{history.length}"
end

Then("the most recent entry should have activity {string}") do |expected|
  history = @vs_audit.history(@vs_audit.store.all.last.target_id)
  assert_equal expected, history.first.activity
end

Then("the most recent entry should have reason {string}") do |expected|
  history = @vs_audit.history(@vs_audit.store.all.last.target_id)
  assert_equal expected, history.first.reason_code
end

Then("the agent history for {string} should have {int} entries") do |agent_id, count|
  history = @vs_audit.agent_history(agent_id)
  assert_equal count, history.length
end

Then("the usage stats for {string} should show {int} total operations") do |vs_id, count|
  @usage_stats = @vs_audit.usage_stats(vs_id)
  assert_equal count, @usage_stats[:total_operations]
end

Then("the usage stats should show {int} unique agents") do |count|
  assert_equal count, @usage_stats[:unique_agents]
end

Then("the first history entry for {string} should be most recent") do |vs_id|
  history = @vs_audit.history(vs_id)
  assert history.length >= 2, "Need at least 2 entries"
  assert history[0].recorded >= history[1].recorded, "First entry should be most recent"
end

Then("the most recent entry for {string} should reference source {string}") do |vs_id, source|
  history = @vs_audit.history(vs_id)
  entry = history.first
  assert_equal "DocumentReference", entry.entity_what_type
  assert_equal source, entry.entity_what_id
end

Then("the expansion metadata should show {int} codes") do |count|
  metadata = JSON.parse(@last_provenance.chain_of_custody)
  assert_equal count, metadata["code_count"]
end

Then("the expansion metadata should show cached true") do
  metadata = JSON.parse(@last_provenance.chain_of_custody)
  assert_equal true, metadata["cached"]
end
