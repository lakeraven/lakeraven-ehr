# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SmartConfigurationControllerTest < ActionDispatch::IntegrationTest
      CONFIG = "/lakeraven-ehr/.well-known/smart-configuration"
      OAUTH_URIS = "http://fhir-registry.smarthealthit.org/StructureDefinition/oauth-uris"

      # The endpoints a client POSTs to. Every other published URL is fetched.
      POST_ENDPOINTS = %w[token_endpoint token].freeze

      test "returns SMART configuration JSON without authentication" do
        get CONFIG

        assert_response :ok
        assert_equal "application/json", response.media_type
        assert JSON.parse(response.body)["token_endpoint"].present?
      end

      # #657. A client that follows discovery must not get a 404 at its next
      # step: every URL smart-configuration publishes is routed.
      test "every URL smart-configuration publishes resolves" do
        get CONFIG
        urls = JSON.parse(response.body).select { |_key, value| value.is_a?(String) && value.start_with?("http") }

        assert_not_empty urls
        urls.each { |key, url| assert_resolves(key, url) }
      end

      # #657. The CapabilityStatement's security element names endpoints
      # from the same source, so its URLs resolve too.
      test "every URL the CapabilityStatement's security element publishes resolves" do
        get "/lakeraven-ehr/metadata"
        security = JSON.parse(response.body).dig("rest", 0, "security")
        oauth = security.fetch("extension").find { |extension| extension["url"] == OAUTH_URIS }
        urls = oauth.fetch("extension").to_h { |extension| [ extension["url"], extension["valueUri"] ] }

        assert_not_empty urls
        urls.each { |key, url| assert_resolves(key, url) }
      end

      test "the CapabilityStatement names each endpoint smart-configuration publishes under the same URL" do
        get CONFIG
        config = JSON.parse(response.body)
        get "/lakeraven-ehr/metadata"
        security = JSON.parse(response.body).dig("rest", 0, "security")
        oauth = security.fetch("extension").find { |extension| extension["url"] == OAUTH_URIS }
        published = oauth.fetch("extension").to_h { |extension| [ "#{extension['url']}_endpoint", extension["valueUri"] ] }

        assert_equal config.slice(*published.keys), published
        assert_equal config.keys.grep(/_endpoint\z/).sort, published.keys.sort
      end

      test "the grant types are the ones the token endpoint accepts" do
        get CONFIG
        grant_types = JSON.parse(response.body)["grant_types_supported"]

        assert_not_empty grant_types
        grant_types.each do |grant_type|
          post "/lakeraven-ehr/oauth/token", params: { grant_type: grant_type }
          refute_equal "unsupported_grant_type", JSON.parse(response.body)["error"], grant_type
        end
      end

      private

      def assert_resolves(key, url)
        path = URI(url).path
        if POST_ENDPOINTS.include?(key)
          post path
        else
          get path
        end

        refute_equal 404, response.status, "#{key} (#{url}) is published but not served"
      end
    end
  end
end
