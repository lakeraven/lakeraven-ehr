# frozen_string_literal: true

require "test_helper"
require "net/http"
require "json"
require "uri"

module Lakeraven
  module EHR
    module FHIR
      # The engine's own FHIR R4 read client (#599). No request leaves the
      # process: Net::HTTP.start is replaced for the length of each example and
      # yields a recording connection. That seam also covers
      # Net::HTTP.get_response, which opens its connection through start.
      class ClientTest < ActiveSupport::TestCase
        BASE_URL = "https://fhir.example.test/fhir"

        PATIENT = {
          "resourceType" => "Patient", "id" => "1",
          "name" => [ { "family" => "Testpatient", "given" => [ "Ada" ] } ],
          "gender" => "female", "birthDate" => "1980-05-15"
        }.freeze

        BUNDLE = {
          "resourceType" => "Bundle", "type" => "searchset", "total" => 1,
          "entry" => [ { "resource" => PATIENT } ]
        }.freeze

        NOT_FOUND = {
          "resourceType" => "OperationOutcome",
          "issue" => [ { "severity" => "error", "code" => "not-found", "diagnostics" => "Patient/404 not found" } ]
        }.freeze

        # Stands in for the Net::HTTP connection. It answers the three ways a
        # GET is sent on one, and records the path and headers of each.
        class RecordingConnection
          attr_reader :requests

          def initialize(response)
            @response = response
            @requests = []
          end

          def request(req, _body = nil)
            headers = {}
            req.each_header { |name, value| headers[name.downcase] = value }
            record(req.method, req.path, headers)
          end

          def get(path, headers = nil, *)
            record("GET", path, normalize(headers))
          end

          def request_get(path, headers = nil, *)
            record("GET", path, normalize(headers))
          end

          private

          def record(method, path, headers)
            path = path.request_uri if path.respond_to?(:request_uri)
            @requests << { method: method, path: path.to_s, headers: headers }
            @response
          end

          def normalize(headers)
            (headers || {}).to_h { |name, value| [ name.to_s.downcase, value ] }
          end
        end

        # --- read -----------------------------------------------------------

        test "read GETs base_url/type/id and returns the parsed resource" do
          result, http = with_http(200, PATIENT.to_json) { client.read("Patient", "1") }

          assert_equal PATIENT, result
          assert_equal 1, http[:requests].length
          assert_equal "GET", http[:requests].first[:method]
          assert_equal "/fhir/Patient/1", http[:requests].first[:path]
        end

        test "read returns a Hash with string keys" do
          result, = with_http(200, PATIENT.to_json) { client.read("Patient", "1") }

          assert_instance_of Hash, result
          assert result.keys.all?(String)
          assert_equal "Testpatient", result["name"].first["family"]
        end

        test "read asks for application/fhir+json" do
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", "1") }

          assert_equal "application/fhir+json", http[:requests].first[:headers]["accept"]
        end

        test "read accepts an Integer id" do
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", 1) }

          assert_equal "/fhir/Patient/1", http[:requests].first[:path]
        end

        test "read connects to the base_url host over TLS for an https base_url" do
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", "1") }

          start = http[:starts].first
          assert_equal "fhir.example.test", start[:args].first
          assert_equal true, start[:opts][:use_ssl]
        end

        test "a trailing slash on base_url does not double the path separator" do
          _, http = with_http(200, PATIENT.to_json) do
            Client.new(base_url: "#{BASE_URL}/").read("Patient", "1")
          end

          assert_equal "/fhir/Patient/1", http[:requests].first[:path]
        end

        test "an id with path separators stays inside its own path segment" do
          id = "1/../Practitioner/2"
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", id) }

          path = http[:requests].first[:path]
          assert path.start_with?("/fhir/Patient/"), "unexpected path #{path}"
          segment = path.delete_prefix("/fhir/Patient/")
          refute_match %r{[/?#]}, segment
          refute_includes path, "/Practitioner/"
          assert_equal id, URI.decode_www_form_component(segment)
        end

        test "an id with a query delimiter cannot start a query string" do
          id = "1?x=y"
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", id) }

          path = http[:requests].first[:path]
          refute_includes path, "?"
          segment = path.delete_prefix("/fhir/Patient/")
          assert_equal id, URI.decode_www_form_component(segment)
        end

        # --- search ---------------------------------------------------------

        test "search GETs base_url/type with the params as a query and returns the Bundle" do
          result, http = with_http(200, BUNDLE.to_json) { client.search("Patient", name: "Testpatient") }

          assert_equal BUNDLE, result
          assert_equal "GET", http[:requests].first[:method]
          assert_equal "/fhir/Patient?name=Testpatient", http[:requests].first[:path]
          assert_equal "application/fhir+json", http[:requests].first[:headers]["accept"]
        end

        test "search form-encodes values so a value cannot inject a parameter" do
          params = { name: "Test Patient&gender=male", "_id" => "1=2" }
          _, http = with_http(200, BUNDLE.to_json) { client.search("Patient", params) }

          path, query = http[:requests].first[:path].split("?", 2)
          assert_equal "/fhir/Patient", path
          assert_equal [ [ "name", "Test Patient&gender=male" ], [ "_id", "1=2" ] ], URI.decode_www_form(query)
          assert_equal 1, query.count("&"), "exactly two parameters must be sent: #{query}"
          refute_includes query, " "
        end

        test "search with no params requests the bare type" do
          _, http = with_http(200, BUNDLE.to_json) { client.search("Patient") }

          assert_equal "/fhir/Patient", http[:requests].first[:path].delete_suffix("?")
        end

        test "search on a base_url with a trailing slash does not double the path separator" do
          _, http = with_http(200, BUNDLE.to_json) do
            Client.new(base_url: "#{BASE_URL}/").search("Patient", name: "Testpatient")
          end

          assert_equal "/fhir/Patient?name=Testpatient", http[:requests].first[:path]
        end

        # --- not found ------------------------------------------------------

        test "a 404 with an OperationOutcome body returns the OperationOutcome" do
          result, = with_http(404, NOT_FOUND.to_json) { client.read("Patient", "404") }

          assert_equal NOT_FOUND, result
        end

        test "a 410 with an OperationOutcome body returns the OperationOutcome" do
          result, = with_http(410, NOT_FOUND.to_json) { client.read("Patient", "404") }

          assert_equal "OperationOutcome", result["resourceType"]
        end

        # --- failures raise; absence of data never reads as success ---------

        test "Error is a StandardError" do
          assert_operator Client::Error, :<, StandardError
        end

        test "a 404 whose body is not an OperationOutcome raises" do
          assert_raises(Client::Error) do
            with_http(404, PATIENT.to_json) { client.read("Patient", "1") }
          end
        end

        test "a 404 whose body is not JSON raises" do
          assert_raises(Client::Error) do
            with_http(404, "<html>Not Found</html>") { client.read("Patient", "1") }
          end
        end

        test "a 500 raises even with an OperationOutcome body" do
          assert_raises(Client::Error) do
            with_http(500, NOT_FOUND.to_json) { client.read("Patient", "1") }
          end
        end

        test "a 401 raises rather than reading as not found" do
          assert_raises(Client::Error) do
            with_http(401, NOT_FOUND.to_json) { client.read("Patient", "1") }
          end
        end

        test "a 302 raises" do
          assert_raises(Client::Error) do
            with_http(302, "") { client.read("Patient", "1") }
          end
        end

        test "an empty 200 body raises" do
          assert_raises(Client::Error) do
            with_http(200, "") { client.read("Patient", "1") }
          end
        end

        test "a nil 200 body raises" do
          assert_raises(Client::Error) do
            with_http(200, nil) { client.read("Patient", "1") }
          end
        end

        test "a 200 body that is not JSON raises" do
          assert_raises(Client::Error) do
            with_http(200, "<html>gateway</html>") { client.read("Patient", "1") }
          end
        end

        test "a 200 body of JSON null raises" do
          assert_raises(Client::Error) do
            with_http(200, "null") { client.read("Patient", "1") }
          end
        end

        test "a 200 body that is a JSON array raises" do
          assert_raises(Client::Error) do
            with_http(200, "[]") { client.read("Patient", "1") }
          end
        end

        test "search raises on a 500" do
          assert_raises(Client::Error) do
            with_http(500, "") { client.search("Patient", name: "Testpatient") }
          end
        end

        test "search raises on an empty 200 body" do
          assert_raises(Client::Error) do
            with_http(200, "") { client.search("Patient", name: "Testpatient") }
          end
        end

        # --- independence from rpms-rpc --------------------------------------

        test "exposes base_url" do
          assert_equal BASE_URL, client.base_url
        end

        test "constructing and using a client calls nothing on RpmsRpc's FHIR surface" do
          StubHelpers.with_recording_stub(RpmsRpc, :fhir_client, nil) do |client_calls|
            StubHelpers.with_recording_stub(RpmsRpc, :warn_fhir_client_deprecated, nil) do |warn_calls|
              with_http(200, PATIENT.to_json) { client.read("Patient", "1") }
              with_http(200, BUNDLE.to_json) { client.search("Patient", name: "Testpatient") }

              assert_empty client_calls
              assert_empty warn_calls
            end
          end
        end

        test "constructing and using a client writes no deprecation warning" do
          _out, err = capture_io do
            with_http(200, PATIENT.to_json) { Client.new(base_url: BASE_URL).read("Patient", "1") }
          end

          refute_match(/deprecat/i, err)
        end

        private

        def client
          Client.new(base_url: BASE_URL)
        end

        def response(status, body)
          code = status.to_s
          klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
          res = klass.new("1.1", code, "status #{code}")
          res.define_singleton_method(:body) { body }
          res
        end

        # Runs the block with Net::HTTP.start replaced. Returns the block's
        # value and what the connection saw.
        def with_http(status, body)
          connection = RecordingConnection.new(response(status, body))
          starts = []
          fake_start = lambda do |*args, **opts, &blk|
            opts = args.pop.merge(opts) if args.last.is_a?(Hash)
            starts << { args: args, opts: opts }
            blk ? blk.call(connection) : connection
          end

          original = Net::HTTP.method(:start)
          Net::HTTP.define_singleton_method(:start, &fake_start)
          begin
            result = yield
          ensure
            Net::HTTP.define_singleton_method(:start, original)
          end
          [ result, { requests: connection.requests, starts: starts } ]
        end
      end
    end
  end
end
