# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "ipaddr"
require "zlib"

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
      # base_url must be https, or plain http to a loopback host, with no
      # userinfo or query. A resource type or id outside FHIR's grammar is
      # refused with ArgumentError before any connection is opened.
      #
      # A 2xx answer returns the parsed resource, and must be the requested
      # type (read) or a Bundle (search). For read, a 404 whose
      # OperationOutcome says not-found, or a 410 whose OperationOutcome says
      # deleted or not-found, returns that OperationOutcome, the way the test
      # double answers for an unknown id. Every other answer, a 404 or 410 to
      # a search included, raises Client::Error, so an outage, an auth failure
      # or a gateway page never reads as "no data". Each call sends one GET:
      # Net::HTTP's idempotent retry is off.
      #
      # Error messages name the resource type and the HTTP status only. They
      # never carry the response body, the URL, or the request's id or params:
      # any of them can hold patient data or credentials.
      class Client
        class Error < StandardError; end

        ACCEPT = "application/fhir+json"
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 15
        RESOURCE_TYPE = /\A[A-Z][A-Za-z]*\z/
        ID = /\A[A-Za-z0-9\-.]{1,64}\z/
        ABSENT_CODES = { "404" => %w[not-found], "410" => %w[deleted not-found] }.freeze
        NETWORK_ERRORS = [
          IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError,
          Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error
        ].freeze

        attr_reader :base_url

        def initialize(base_url:, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
          @base_uri = validated_base_uri(base_url)
          @base_url = base_url
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        def read(resource_type, id)
          resource_type = validated_type(resource_type)
          id = id.to_s
          raise ArgumentError, "FHIR id is outside FHIR's id grammar" unless ID.match?(id) && !%w[. ..].include?(id)

          get(resource_type, "#{type_path(resource_type)}/#{id}", resource_type, absent_ok: true)
        end

        # A search with no matches is a 200 with an empty Bundle, so a 404 or
        # 410 here means the type or endpoint is missing and always raises.
        def search(resource_type, params = {})
          resource_type = validated_type(resource_type)
          params = {} if params.nil?
          raise ArgumentError, "FHIR search params must be a Hash" unless params.is_a?(Hash)

          path = type_path(resource_type)
          path = "#{path}?#{URI.encode_www_form(params)}" unless params.empty?
          get(resource_type, path, "Bundle", absent_ok: false)
        end

        private

        def validated_base_uri(base_url)
          uri = begin
            URI.parse(base_url.to_s)
          rescue URI::Error
            raise ArgumentError, "FHIR base_url is not a valid URI", cause: nil
          end
          raise ArgumentError, "FHIR base_url must be http or https" unless %w[http https].include?(uri.scheme)
          raise ArgumentError, "FHIR base_url must name a host" if uri.host.to_s.empty?
          raise ArgumentError, "FHIR base_url must not carry a query" unless uri.query.nil?
          raise ArgumentError, "FHIR base_url must not carry userinfo" unless uri.userinfo.nil?
          if uri.scheme == "http" && !loopback?(uri.hostname)
            raise ArgumentError, "FHIR base_url must use https unless the host is loopback"
          end

          uri
        end

        def loopback?(host)
          host == "localhost" || IPAddr.new(host).loopback?
        rescue IPAddr::Error
          false
        end

        def validated_type(resource_type)
          resource_type = resource_type.to_s
          raise ArgumentError, "FHIR resource type is not a resource type name" unless RESOURCE_TYPE.match?(resource_type)

          resource_type
        end

        def type_path(resource_type)
          "#{@base_uri.path.delete_suffix('/')}/#{resource_type}"
        end

        def get(resource_type, path, expected_type, absent_ok:)
          response = Net::HTTP.start(
            @base_uri.hostname, @base_uri.port,
            use_ssl: @base_uri.scheme == "https",
            open_timeout: @open_timeout, read_timeout: @read_timeout, max_retries: 0
          ) do |http|
            http.request(Net::HTTP::Get.new(path, "Accept" => ACCEPT))
          end
          handle(resource_type, response, expected_type, absent_ok)
        rescue *NETWORK_ERRORS => e
          raise Error, "FHIR #{resource_type} request failed (#{e.class})", cause: nil
        end

        def handle(resource_type, response, expected_type, absent_ok)
          code = response.code.to_s
          if code.start_with?("2")
            resource = parse(resource_type, code, response.body)
            return resource if resource["resourceType"] == expected_type

            raise Error, "FHIR #{resource_type} request answered #{code} with an unexpected resource type"
          elsif absent_ok && ABSENT_CODES.key?(code)
            outcome = parse(resource_type, code, response.body)
            return outcome if absent_outcome?(outcome, ABSENT_CODES[code])

            raise Error, "FHIR #{resource_type} request answered #{code} without a matching OperationOutcome"
          else
            raise Error, "FHIR #{resource_type} request answered #{code}"
          end
        end

        def absent_outcome?(outcome, codes)
          outcome["resourceType"] == "OperationOutcome" &&
            Array(outcome["issue"]).any? { |issue| issue.is_a?(Hash) && codes.include?(issue["code"]) }
        end

        def parse(resource_type, code, body)
          parsed = JSON.parse(body.to_s)
          return parsed if parsed.is_a?(Hash)

          raise Error, "FHIR #{resource_type} request answered #{code} with a body that is not a JSON object"
        rescue JSON::ParserError
          raise Error, "FHIR #{resource_type} request answered #{code} with a body that is not JSON", cause: nil
        end
      end
    end
  end
end
