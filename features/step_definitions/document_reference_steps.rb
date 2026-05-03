# frozen_string_literal: true

# DocumentReference step definitions

Given("a document reference with type {string} for patient {string}") do |type, dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(
    subject_patient_dfn: dfn, type_code: type, type_display: type.tr("-", " ").capitalize, status: "current"
  )
end

Given("a document reference with type {string} and display {string} for patient {string}") do |type, display, dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(
    subject_patient_dfn: dfn, type_code: type, type_display: display, status: "current"
  )
end

Given("a document reference without a patient") do
  @doc_ref = Lakeraven::EHR::DocumentReference.new(type_code: "clinical-note", status: "current")
end

Given("a document reference without a type for patient {string}") do |dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(subject_patient_dfn: dfn, status: "current")
end

Given("a document reference with status {string} for patient {string}") do |status, dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(
    subject_patient_dfn: dfn, type_code: "clinical-note", type_display: "Note", status: status
  )
end

Given("a document reference with author {string} for patient {string}") do |author, dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(
    subject_patient_dfn: dfn, type_code: "clinical-note", type_display: "Note",
    status: "current", author_ien: author
  )
end

Given("a document reference dated {string} for patient {string}") do |date, dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(
    subject_patient_dfn: dfn, type_code: "clinical-note", type_display: "Note",
    status: "current", date: Date.parse(date)
  )
end

Given("a document reference with category {string} for patient {string}") do |category, dfn|
  @doc_ref = Lakeraven::EHR::DocumentReference.new(
    subject_patient_dfn: dfn, type_code: "clinical-note", type_display: "Note",
    status: "current", category: category
  )
end

When("I serialize the document reference to FHIR") do
  @fhir = @doc_ref.to_fhir
end

Then("the document reference should be valid") do
  assert @doc_ref.valid?, "Expected valid: #{@doc_ref.errors.full_messages}"
end

Then("the document reference should be invalid") do
  refute @doc_ref.valid?
end

Then("the document status should be {string}") do |status|
  assert_equal status, @doc_ref.status
end

Then("the document type display should be {string}") do |display|
  assert_equal display, @doc_ref.type_display
end

Then("the document author should be {string}") do |author|
  assert_equal author, @doc_ref.author_ien.to_s
end

Then("the document date should be {string}") do |date|
  assert_equal Date.parse(date), @doc_ref.date
end

# "the FHIR subject reference should be" defined elsewhere

Then("the FHIR type should have display {string}") do |display|
  type = @fhir[:type]
  refute_nil type
  coding = type[:coding]&.first || type
  assert_equal display, (coding[:display] || type[:text])
end

Then("the FHIR document status should be {string}") do |status|
  assert_equal status, @fhir[:status]
end
