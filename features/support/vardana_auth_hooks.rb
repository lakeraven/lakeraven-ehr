# frozen_string_literal: true

# Clean OAuth state between Vardana auth conformance scenarios.
Before("@vardana_auth") do
  Doorkeeper::AccessToken.delete_all if defined?(Doorkeeper::AccessToken)
  Doorkeeper::Application.delete_all if defined?(Doorkeeper::Application)
  if defined?(Lakeraven::EHR::AssertionReplayGuard)
    Lakeraven::EHR::AssertionReplayGuard.reset!
  end
  Lakeraven::EHR.configuration.token_endpoint_url = nil
  @fhir_headers = nil
  @response_json = nil
end

After("@vardana_auth") do
  Lakeraven::EHR.configuration.token_endpoint_url = nil
  Lakeraven::EHR::ClientJwks.resolver = nil if defined?(Lakeraven::EHR::ClientJwks)
end

# JWKS transport scenarios intercept HTTP with WebMock; everything else runs
# with WebMock fully disabled so no other scenario's traffic is affected.
Before("@webmock") do
  require "webmock"
  self.class.include(WebMock::API) unless self.class.include?(WebMock::API)
  WebMock.enable!
  WebMock.disable_net_connect!
end

After("@webmock") do
  WebMock.reset!
  WebMock.allow_net_connect!
  WebMock.disable!
end

# The no-nil-caching scenario needs a REAL cache store: the test default
# (:null_store) never returns hits, which would make the assertion vacuous.
Before("@jwks_cache") do
  @vardana_original_cache = Rails.cache
  Rails.cache = ActiveSupport::Cache::MemoryStore.new
end

After("@jwks_cache") do
  Rails.cache = @vardana_original_cache
end
