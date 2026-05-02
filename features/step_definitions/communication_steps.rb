# frozen_string_literal: true

# Communication step definitions

Given("a communication with content {string} from {string} {string} for patient {string}") do |content, sender_type, sender_id, dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, sender_type: sender_type, sender_id: sender_id,
    payload_content: content, status: "completed"
  )
end

Given("a communication without a patient") do
  @communication = Lakeraven::EHR::Communication.new(
    sender_id: "201", payload_content: "test"
  )
end

Given("a communication without a sender for patient {string}") do |dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, payload_content: "test"
  )
end

Given("a communication without content from {string} {string} for patient {string}") do |sender_type, sender_id, dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, sender_type: sender_type, sender_id: sender_id
  )
end

Given("a communication with status {string} from {string} {string} for patient {string}") do |status, sender_type, sender_id, dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, sender_type: sender_type, sender_id: sender_id,
    payload_content: "test", status: status
  )
end

Given("a communication with priority {string} from {string} {string} for patient {string}") do |priority, sender_type, sender_id, dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, sender_type: sender_type, sender_id: sender_id,
    payload_content: "test", status: "completed", priority: priority
  )
end

Given("a communication with category {string} from {string} {string} for patient {string}") do |category, sender_type, sender_id, dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, sender_type: sender_type, sender_id: sender_id,
    payload_content: "test", status: "completed", category: category
  )
end

Given("a communication replying to message {string} from {string} {string} for patient {string}") do |parent_id, sender_type, sender_id, dfn|
  @communication = Lakeraven::EHR::Communication.new(
    subject_patient_dfn: dfn, sender_type: sender_type, sender_id: sender_id,
    payload_content: "reply", status: "completed", parent_message_id: parent_id
  )
end

When("I serialize the communication to FHIR") do
  @fhir = @communication.to_fhir
end

Then("the communication should be valid") do
  assert @communication.valid?, "Expected valid: #{@communication.errors.full_messages}"
end

Then("the communication should be invalid") do
  refute @communication.valid?
end

Then("the communication should be completed") do
  assert @communication.completed?, "Expected completed"
end

Then("the communication should be urgent") do
  assert @communication.urgent?, "Expected urgent"
end

Then("the communication should be an alert") do
  assert @communication.alert?, "Expected alert"
end

Then("the communication should be a root message") do
  assert @communication.root_message?, "Expected root message"
end

Then("the communication should be a reply") do
  assert @communication.reply?, "Expected reply"
end

Then("the FHIR communication payload should include {string}") do |text|
  payload = @fhir[:payload]
  refute_nil payload
  assert payload.any? { |p| p[:contentString]&.include?(text) },
    "Expected payload to include '#{text}'"
end
