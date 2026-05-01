# frozen_string_literal: true

# Clean up records between scenarios to prevent cross-contamination.
Before("@onc") do
  Lakeraven::EHR::AuditEvent.delete_all
  Lakeraven::EHR::AmendmentRequest.delete_all if defined?(Lakeraven::EHR::AmendmentRequest)
  Lakeraven::EHR::Disclosure.delete_all if defined?(Lakeraven::EHR::Disclosure)
  Doorkeeper::AccessToken.delete_all if defined?(Doorkeeper::AccessToken)
  Doorkeeper::Application.delete_all if defined?(Doorkeeper::Application)
  @oauth_app = nil
  @emergency_accesses = []
end
