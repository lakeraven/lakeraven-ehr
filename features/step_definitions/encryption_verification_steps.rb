# frozen_string_literal: true

When("I run the encryption verification") do
  @encryption_report = Lakeraven::EHR::EncryptionVerificationService.new.run
end

Then("the report should include {string}") do |text|
  report_text = @encryption_report.to_s
  assert report_text.downcase.include?(text.downcase), "Expected report to include '#{text}'"
end

Then("the report should include the database SSL status") do
  assert @encryption_report[:database_ssl].present?
end

Then("the report should include ActiveRecord encryption status") do
  assert @encryption_report[:active_record_encryption].present?
end

Then("the report should list encrypted columns") do
  assert @encryption_report.key?(:encrypted_columns)
end

Then("the report should indicate storage encryption requires external verification") do
  assert @encryption_report.dig(:infrastructure_attestation, :required)
end
