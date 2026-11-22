# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Lakeraven
  module EHR
    module FHIR
      # The engine's FHIR R4 read client (#599): read and search against one
      # FHIR endpoint over HTTP(S). It replaces the client rpms-rpc carried,
      # which leaves that gem (ADR 0010: a FHIR client is host knowledge).
      #
      #   client = Lakeraven::EHR::FHIR::Client.new(base_url: "https://fhir.example.test/fhir")
      #   client.read("Patient", "1")              # => { "resourceType" => "Patient", ... }
      #   client.search("Patient", name: "Smith")  # => { "resourceType" => "Bundle", ... }
      #
      # A 2xx answer returns the parsed resource. A 404 or 410 that carries an
      # OperationOutcome returns that OperationOutcome, the way the test double
      # answers for an unknown id. Every other answer raises Client::Error, so
      # an outage, an auth failure or a gateway page never reads as "no data".
      #
      # Error messages name the resource type and the HTTP status only. They
      # never carry the response body or the request's id or params: either can
      # hold patient data.
      class Client
        class Error < StandardError; end

        ACCEPT = "application/fhir+json"
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 15
        NOT_FOUND_CODES = %w[404 410].freeze
        NETWORK_ERRORS = [
          IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
        ].freeze

        attr_reader :base_url

        def initialize(base_url:, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
          @base_url = base_url
          @base_uri = URI.parse(base_url.to_s.delete_suffix("/"))
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        def read(resource_type, id)
          get(resource_type, "#{type_path(resource_type)}/#{URI.encode_uri_component(id.to_s)}")
        end

        def search(resource_type, params = {})
          path = type_path(resource_type)
          path = "#{path}?#{URI.encode_www_form(params)}" unless params.nil? || params.empty?
          get(resource_type, path)
        end

        private

        def type_path(resource_type)
          "#{@base_uri.path}/#{URI.encode_uri_component(resource_type.to_s)}"
        end

        def get(resource_type, path)
          response = Net::HTTP.start(
            @base_uri.host, @base_uri.port,
            use_ssl: @base_uri.scheme == "https",
            open_timeout: @open_timeout, read_timeout: @read_timeout
          ) do |http|
            http.request(Net::HTTP::Get.new(path, "Accept" => ACCEPT))
          end
          handle(resource_type, response)
        rescue *NETWORK_ERRORS => e
          raise Error, "FHIR #{resource_type} request failed (#{e.class})"
        end

        def handle(resource_type, response)
          code = response.code.to_s
          if code.start_with?("2")
            parse(resource_type, code, response.body)
          elsif NOT_FOUND_CODES.include?(code)
            outcome = parse(resource_type, code, response.body)
            return outcome if outcome["resourceType"] == "OperationOutcome"

            raise Error, "FHIR #{resource_type} request answered #{code} without an OperationOutcome"
          else
            raise Error, "FHIR #{resource_type} request answered #{code}"
          end
        end

        def parse(resource_type, code, body)
          parsed = JSON.parse(body.to_s)
          return parsed if parsed.is_a?(Hash)

          raise Error, "FHIR #{resource_type} request answered #{code} with a body that is not a JSON object"
        rescue JSON::ParserError
          raise Error, "FHIR #{resource_type} request answered #{code} with a body that is not JSON"
        end
      end
    end
  end
end
