# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Lakeraven
  module EHR
    # VSAC (Value Set Authority Center) FHIR API Client
    #
    # VSAC provides standard value sets used in eCQMs (electronic Clinical Quality Measures).
    # Requires UMLS API key (free registration at https://uts.nlm.nih.gov/uts/)
    #
    # API Documentation: https://www.nlm.nih.gov/vsac/support/usingvsac/vsacfhirapi.html
    #
    # Ported from rpms_redux VsacClient.
    #
    # Usage:
    #   client = Lakeraven::EHR::VsacClient.new(api_key: ENV["UMLS_API_KEY"])
    #   valueset = client.fetch_valueset("2.16.840.1.113883.3.464.1003.103.12.1001")
    #   expanded = client.expand_valueset("2.16.840.1.113883.3.464.1003.103.12.1001")
    class VsacClient
      BASE_URL = "https://cts.nlm.nih.gov/fhir"

      class AuthenticationError < StandardError; end
      class NotFoundError < StandardError; end
      class ApiError < StandardError; end

      def initialize(api_key: nil)
        @api_key = api_key || ENV["UMLS_API_KEY"]
        raise AuthenticationError, "UMLS API key required. Set UMLS_API_KEY env var." unless @api_key
      end

      # Fetch ValueSet definition (without expansion)
      def fetch_valueset(oid)
        response = get("/ValueSet/#{oid}")
        JSON.parse(response.body)
      end

      # Expand ValueSet to get all codes
      def expand_valueset(oid, include_designations: false)
        params = {}
        params[:includeDesignations] = true if include_designations

        response = get("/ValueSet/#{oid}/$expand", params)
        JSON.parse(response.body)
      end

      # Search for ValueSets by name or title
      def search_valuesets(query, count: 20)
        response = get("/ValueSet", { name: query, _count: count })
        result = JSON.parse(response.body)
        result["entry"]&.map { |e| e["resource"] } || []
      end

      # List all available ValueSets (paginated)
      def list_valuesets(count: 100, offset: 0)
        response = get("/ValueSet", { _count: count, _offset: offset })
        result = JSON.parse(response.body)
        {
          total: result["total"],
          valuesets: result["entry"]&.map { |e| e["resource"] } || []
        }
      end

      # Fetch multiple ValueSets by OIDs
      def fetch_valuesets(oids)
        oids.map do |oid|
          begin
            { oid: oid, valueset: expand_valueset(oid) }
          rescue NotFoundError
            { oid: oid, error: "Not found" }
          rescue ApiError => e
            { oid: oid, error: e.message }
          end
        end
      end

      # Check if API key is valid
      def valid_credentials?
        response = get("/metadata")
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      private

      def get(path, params = {})
        uri = URI("#{BASE_URL}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?

        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/fhir+json"
        request.basic_auth("apikey", @api_key)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        handle_response(response)
      end

      def handle_response(response)
        case response
        when Net::HTTPSuccess
          response
        when Net::HTTPUnauthorized
          raise AuthenticationError, "Invalid UMLS API key"
        when Net::HTTPNotFound
          raise NotFoundError, "ValueSet not found"
        else
          raise ApiError, "VSAC API error: #{response.code} #{response.message}"
        end
      end
    end
  end
end
