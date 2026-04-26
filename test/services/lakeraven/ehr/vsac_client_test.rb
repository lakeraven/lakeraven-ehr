# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VsacClientTest < ActiveSupport::TestCase
      # =========================================================================
      # INITIALIZATION
      # =========================================================================

      test "raises AuthenticationError when no API key provided" do
        original = ENV["UMLS_API_KEY"]
        ENV["UMLS_API_KEY"] = nil
        assert_raises(VsacClient::AuthenticationError) { VsacClient.new }
      ensure
        ENV["UMLS_API_KEY"] = original
      end

      test "accepts explicit api_key argument" do
        client = VsacClient.new(api_key: "test-key")
        assert_instance_of VsacClient, client
      end

      test "falls back to UMLS_API_KEY env var" do
        original = ENV["UMLS_API_KEY"]
        ENV["UMLS_API_KEY"] = "env-key"
        client = VsacClient.new
        assert_instance_of VsacClient, client
      ensure
        ENV["UMLS_API_KEY"] = original
      end

      # =========================================================================
      # FETCH VALUESET
      # =========================================================================

      test "fetch_valueset parses JSON response" do
        client = build_client
        body = { "resourceType" => "ValueSet", "id" => "123" }
        install_http_mock(client, Net::HTTPSuccess, body.to_json)

        result = client.fetch_valueset("2.16.840.1.113883.3.464.1003.103.12.1001")
        assert_equal "ValueSet", result["resourceType"]
      end

      test "fetch_valueset raises NotFoundError on 404" do
        client = build_client
        install_http_mock(client, Net::HTTPNotFound, "")

        assert_raises(VsacClient::NotFoundError) do
          client.fetch_valueset("nonexistent-oid")
        end
      end

      test "fetch_valueset raises AuthenticationError on 401" do
        client = build_client
        install_http_mock(client, Net::HTTPUnauthorized, "")

        assert_raises(VsacClient::AuthenticationError) do
          client.fetch_valueset("some-oid")
        end
      end

      # =========================================================================
      # EXPAND VALUESET
      # =========================================================================

      test "expand_valueset returns parsed expansion" do
        client = build_client
        body = { "resourceType" => "ValueSet", "expansion" => { "contains" => [] } }
        install_http_mock(client, Net::HTTPSuccess, body.to_json)

        result = client.expand_valueset("2.16.840.1.113883.3.464.1003.103.12.1001")
        assert result.key?("expansion")
      end

      test "expand_valueset raises ApiError on server error" do
        client = build_client
        install_http_mock(client, Net::HTTPServerError, "", code: "500", message: "Internal Server Error")

        assert_raises(VsacClient::ApiError) do
          client.expand_valueset("some-oid")
        end
      end

      # =========================================================================
      # SEARCH VALUESETS
      # =========================================================================

      test "search_valuesets extracts resources from bundle entries" do
        client = build_client
        body = {
          "resourceType" => "Bundle",
          "entry" => [
            { "resource" => { "resourceType" => "ValueSet", "name" => "Diabetes" } }
          ]
        }
        install_http_mock(client, Net::HTTPSuccess, body.to_json)

        results = client.search_valuesets("Diabetes")
        assert_equal 1, results.length
        assert_equal "Diabetes", results.first["name"]
      end

      test "search_valuesets returns empty array when no entries" do
        client = build_client
        body = { "resourceType" => "Bundle" }
        install_http_mock(client, Net::HTTPSuccess, body.to_json)

        results = client.search_valuesets("nothing")
        assert_equal [], results
      end

      # =========================================================================
      # LIST VALUESETS
      # =========================================================================

      test "list_valuesets returns total and valuesets" do
        client = build_client
        body = {
          "resourceType" => "Bundle",
          "total" => 42,
          "entry" => [
            { "resource" => { "resourceType" => "ValueSet", "id" => "1" } }
          ]
        }
        install_http_mock(client, Net::HTTPSuccess, body.to_json)

        result = client.list_valuesets(count: 10, offset: 0)
        assert_equal 42, result[:total]
        assert_equal 1, result[:valuesets].length
      end

      # =========================================================================
      # FETCH MULTIPLE VALUESETS
      # =========================================================================

      test "fetch_valuesets collects results for multiple OIDs" do
        client = build_client
        body = { "resourceType" => "ValueSet", "expansion" => {} }
        install_http_mock(client, Net::HTTPSuccess, body.to_json)

        results = client.fetch_valuesets([ "oid1", "oid2" ])
        assert_equal 2, results.length
        assert results.all? { |r| r[:valueset] }
      end

      test "fetch_valuesets handles NotFoundError for individual OIDs" do
        client = build_client
        install_http_mock(client, Net::HTTPNotFound, "")

        results = client.fetch_valuesets([ "bad-oid" ])
        assert_equal "Not found", results.first[:error]
      end

      test "fetch_valuesets handles ApiError for individual OIDs" do
        client = build_client
        install_http_mock(client, Net::HTTPServerError, "", code: "500", message: "Internal Server Error")

        results = client.fetch_valuesets([ "error-oid" ])
        assert results.first[:error].present?
      end

      # =========================================================================
      # VALID CREDENTIALS
      # =========================================================================

      test "valid_credentials? returns true on success" do
        client = build_client
        install_http_mock(client, Net::HTTPSuccess, "{}")

        assert client.valid_credentials?
      end

      test "valid_credentials? returns false on failure" do
        client = build_client
        install_http_mock(client, Net::HTTPUnauthorized, "")

        refute client.valid_credentials?
      end

      # =========================================================================
      # ERROR CLASSES
      # =========================================================================

      test "error classes inherit from StandardError" do
        assert VsacClient::AuthenticationError < StandardError
        assert VsacClient::NotFoundError < StandardError
        assert VsacClient::ApiError < StandardError
      end

      private

      def build_client
        VsacClient.new(api_key: "test-key")
      end

      def install_http_mock(client, response_class, body, code: nil, message: nil)
        resp_code = code || "200"
        resp_message = message || "OK"

        # Override get to return a mock response or raise the appropriate error
        # This avoids case/when === issues with plain Ruby mocks
        client.define_singleton_method(:get) do |_path, _params = {}|
          if response_class <= Net::HTTPSuccess
            mock_resp = Object.new
            mock_resp.define_singleton_method(:body) { body }
            mock_resp.define_singleton_method(:is_a?) { |klass| Net::HTTPSuccess <= klass }
            mock_resp
          elsif response_class <= Net::HTTPUnauthorized
            raise VsacClient::AuthenticationError, "Invalid UMLS API key"
          elsif response_class <= Net::HTTPNotFound
            raise VsacClient::NotFoundError, "ValueSet not found"
          else
            raise VsacClient::ApiError, "VSAC API error: #{resp_code} #{resp_message}"
          end
        end
      end
    end
  end
end
