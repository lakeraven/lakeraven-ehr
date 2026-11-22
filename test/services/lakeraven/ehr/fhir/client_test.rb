# frozen_string_literal: true

require "test_helper"
require "net/http"
require "json"
require "uri"
require "zlib"

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

        # Factory-Spec-Amendment (#599 review round 1): these two examples used
        # to pin that such an id was percent-encoded into one path segment and
        # sent. An id outside FHIR's id grammar is now refused before any
        # request, so nothing that is not an id reaches the endpoint at all.
        test "an id with path separators is refused before any request" do
          assert_refused_before_any_request { |c| c.read("Patient", "1/../Practitioner/2") }
        end

        test "an id with a query delimiter is refused before any request" do
          assert_refused_before_any_request { |c| c.read("Patient", "1?x=y") }
        end

        # --- argument validation: nothing malformed is ever sent -------------

        {
          "nil" => nil,
          "empty" => "",
          "a single dot" => ".",
          "two dots" => "..",
          "65 characters" => "a" * 65,
          "a slash" => "1/2",
          "a space" => "a b",
          "a percent escape" => "1%2F2",
          "an underscore" => "a_b",
          "a trailing newline" => "1\n"
        }.each do |label, id|
          test "read refuses an id that is #{label} before any request" do
            assert_refused_before_any_request { |c| c.read("Patient", id) }
          end
        end

        test "read accepts an id of 64 characters from FHIR's id grammar" do
          id = "#{'A' * 30}-#{'z' * 30}.09"
          assert_equal 64, id.length
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", id) }

          assert_equal "/fhir/Patient/#{id}", http[:requests].first[:path]
        end

        {
          "nil" => nil,
          "empty" => "",
          "two dots" => "..",
          "a type and an id" => "Patient/1",
          "lower case" => "patient",
          "a type with a query" => "Patient?x=y",
          "a type with a digit" => "Patient1",
          "a type with a trailing newline" => "Patient\n"
        }.each do |label, type|
          test "read refuses a resource type that is #{label} before any request" do
            assert_refused_before_any_request { |c| c.read(type, "1") }
          end

          test "search refuses a resource type that is #{label} before any request" do
            assert_refused_before_any_request { |c| c.search(type, name: "Testpatient") }
          end
        end

        # --- base_url validation at construction -----------------------------

        {
          "nil" => nil,
          "empty" => "",
          "without a scheme" => "fhir.example.test/fhir",
          "ftp" => "ftp://fhir.example.test/fhir",
          "carrying a query" => "https://fhir.example.test/fhir?tenant=a",
          "carrying userinfo" => "https://user:SECRETPW@fhir.example.test/fhir",
          "plain http to a host that is not loopback" => "http://fhir.example.test/fhir"
        }.each do |label, url|
          test "new refuses a base_url that is #{label}" do
            assert_raises(ArgumentError) { Client.new(base_url: url) }
          end
        end

        test "the refusal of a base_url with userinfo names neither the credentials nor the URL" do
          url = "https://user:SECRETPW@fhir.example.test/fhir"
          error = assert_raises(ArgumentError) { Client.new(base_url: url) }

          refute_includes error.message, "SECRETPW"
          refute_includes error.message, "pw"
          refute_includes error.message, "user:"
          refute_includes error.message, url
          refute_includes error.message, "fhir.example.test"
        end

        test "the refusal of a base_url with a query does not repeat the URL" do
          url = "https://fhir.example.test/fhir?tenant=SECRETTENANT"
          error = assert_raises(ArgumentError) { Client.new(base_url: url) }

          refute_includes error.message, "SECRETTENANT"
          refute_includes error.message, url
        end

        {
          "https://fhir.example.test/fhir" => [ "fhir.example.test", 443, true, "/fhir/Patient/1" ],
          "https://fhir.example.test/fhir/" => [ "fhir.example.test", 443, true, "/fhir/Patient/1" ],
          "http://127.0.0.1:52773/fhir/r4" => [ "127.0.0.1", 52773, false, "/fhir/r4/Patient/1" ],
          "http://localhost:8080/fhir" => [ "localhost", 8080, false, "/fhir/Patient/1" ],
          "http://[::1]:8080/fhir" => [ "::1", 8080, false, "/fhir/Patient/1" ]
        }.each do |url, (host, port, tls, path)|
          test "new accepts #{url} and reads from it" do
            _, http = with_http(200, PATIENT.to_json) { Client.new(base_url: url).read("Patient", "1") }

            start = http[:starts].first
            assert_equal host, start[:args][0].to_s.delete("[]")
            assert_equal port, start[:args][1]
            assert_equal tls, start[:opts][:use_ssl] ? true : false
            assert_equal path, http[:requests].first[:path]
          end
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

        test "a 410 whose OperationOutcome says deleted returns the OperationOutcome" do
          result, = with_http(410, outcome("deleted").to_json) { client.read("Patient", "404") }

          assert_equal outcome("deleted"), result
        end

        test "a 404 OperationOutcome whose only issue is not-supported raises" do
          assert_raises(Client::Error) do
            with_http(404, outcome("not-supported").to_json) { client.read("Patient", "1") }
          end
        end

        test "a 404 OperationOutcome whose only issue is deleted raises" do
          assert_raises(Client::Error) do
            with_http(404, outcome("deleted").to_json) { client.read("Patient", "1") }
          end
        end

        test "a 410 OperationOutcome whose only issue is processing raises" do
          assert_raises(Client::Error) do
            with_http(410, outcome("processing").to_json) { client.read("Patient", "1") }
          end
        end

        test "a 404 OperationOutcome with no issues raises" do
          assert_raises(Client::Error) do
            with_http(404, { "resourceType" => "OperationOutcome", "issue" => [] }.to_json) { client.read("Patient", "1") }
          end
        end

        test "a 404 search whose OperationOutcome is not-supported raises" do
          assert_raises(Client::Error) do
            with_http(404, outcome("not-supported").to_json) { client.search("Patient", name: "Testpatient") }
          end
        end

        # --- a 2xx must be what was asked for --------------------------------

        test "read raises when a 200 carries an OperationOutcome" do
          assert_raises(Client::Error) do
            with_http(200, NOT_FOUND.to_json) { client.read("Patient", "1") }
          end
        end

        test "read raises when a 200 carries a Bundle" do
          assert_raises(Client::Error) do
            with_http(200, BUNDLE.to_json) { client.read("Patient", "1") }
          end
        end

        test "read raises when a 200 carries another resource type" do
          body = { "resourceType" => "Practitioner", "id" => "1" }.to_json
          assert_raises(Client::Error) do
            with_http(200, body) { client.read("Patient", "1") }
          end
        end

        test "read raises when a 200 carries an object with no resourceType" do
          assert_raises(Client::Error) do
            with_http(200, "{}") { client.read("Patient", "1") }
          end
        end

        test "search raises when a 200 carries a resource that is not a Bundle" do
          assert_raises(Client::Error) do
            with_http(200, PATIENT.to_json) { client.search("Patient", name: "Testpatient") }
          end
        end

        test "search raises when a 200 carries an OperationOutcome" do
          assert_raises(Client::Error) do
            with_http(200, NOT_FOUND.to_json) { client.search("Patient", name: "Testpatient") }
          end
        end

        # --- transport failures ---------------------------------------------

        test "a malformed status line becomes Client::Error and its text is not repeated" do
          error = assert_raises(Client::Error) do
            with_failing_http(Net::HTTPBadResponse.new("wrong status line: SECRETBODY")) { client.read("Patient", "1") }
          end

          refute_includes error.message, "SECRETBODY"
        end

        test "a corrupt compressed body becomes Client::Error and its text is not repeated" do
          error = assert_raises(Client::Error) do
            with_failing_http(Zlib::DataError.new("incorrect header check SECRETBODY")) { client.search("Patient", name: "Testpatient") }
          end

          refute_includes error.message, "SECRETBODY"
        end

        test "a refused connection becomes Client::Error" do
          assert_raises(Client::Error) do
            with_failing_http(Errno::ECONNREFUSED.new("connect(2) for fhir.example.test")) { client.read("Patient", "1") }
          end
        end

        test "a read timeout becomes Client::Error" do
          assert_raises(Client::Error) do
            with_failing_http(Net::ReadTimeout.new) { client.read("Patient", "1") }
          end
        end

        test "the open and read timeouts are passed to the connection" do
          _, http = with_http(200, PATIENT.to_json) do
            Client.new(base_url: BASE_URL, open_timeout: 2, read_timeout: 7).read("Patient", "1")
          end

          assert_equal 2, http[:starts].first[:opts][:open_timeout]
          assert_equal 7, http[:starts].first[:opts][:read_timeout]
        end

        test "the default timeouts are passed to the connection" do
          _, http = with_http(200, PATIENT.to_json) { client.read("Patient", "1") }

          assert_equal Client::OPEN_TIMEOUT, http[:starts].first[:opts][:open_timeout]
          assert_equal Client::READ_TIMEOUT, http[:starts].first[:opts][:read_timeout]
        end

        # --- error messages carry no id, params or body ----------------------

        test "a read error names neither the id nor the response body" do
          body = { "resourceType" => "OperationOutcome", "issue" => [ { "diagnostics" => "BODYMARKER IDMARKER-77" } ] }.to_json
          error = assert_raises(Client::Error) do
            with_http(500, body) { client.read("Patient", "IDMARKER-77") }
          end

          refute_includes error.message, "IDMARKER"
          refute_includes error.message, "BODYMARKER"
        end

        test "a search error names neither the params nor the response body" do
          error = assert_raises(Client::Error) do
            with_http(500, "BODYMARKER PARAMMARKER") { client.search("Patient", name: "PARAMMARKER") }
          end

          refute_includes error.message, "PARAMMARKER"
          refute_includes error.message, "BODYMARKER"
        end

        test "a wrong resource type error names neither the id nor the response body" do
          body = { "resourceType" => "Practitioner", "id" => "IDMARKER-77", "text" => "BODYMARKER" }.to_json
          error = assert_raises(Client::Error) do
            with_http(200, body) { client.read("Patient", "IDMARKER-77") }
          end

          refute_includes error.message, "IDMARKER"
          refute_includes error.message, "BODYMARKER"
        end

        test "a transport error names neither the id nor the params" do
          read_error = assert_raises(Client::Error) do
            with_failing_http(Errno::ECONNREFUSED.new("IDMARKER-77")) { client.read("Patient", "IDMARKER-77") }
          end
          search_error = assert_raises(Client::Error) do
            with_failing_http(Net::ReadTimeout.new("PARAMMARKER")) { client.search("Patient", name: "PARAMMARKER") }
          end

          refute_includes read_error.message, "IDMARKER"
          refute_includes search_error.message, "PARAMMARKER"
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

        def outcome(code)
          {
            "resourceType" => "OperationOutcome",
            "issue" => [ { "severity" => "error", "code" => code, "diagnostics" => "synthetic #{code}" } ]
          }
        end

        # Runs the block with Net::HTTP.start replaced. Returns the block's
        # value and what the connection saw.
        def with_http(status, body)
          connection = RecordingConnection.new(response(status, body))
          starts = []
          result = with_start(recording_start(connection, starts)) { yield }
          [ result, { requests: connection.requests, starts: starts } ]
        end

        # Runs the block with a Net::HTTP.start that raises the given error,
        # the way a connection that fails in transport does.
        def with_failing_http(error)
          with_start(->(*, **, &_blk) { raise error }) { yield }
        end

        # The block is given a client and must raise ArgumentError without
        # opening a connection or sending a request.
        def assert_refused_before_any_request
          connection = RecordingConnection.new(response(200, PATIENT.to_json))
          starts = []
          subject = client
          with_start(recording_start(connection, starts)) do
            assert_raises(ArgumentError) { yield subject }
          end

          assert_empty connection.requests, "a request was sent"
          assert_empty starts, "a connection was opened"
        end

        def recording_start(connection, starts)
          lambda do |*args, **opts, &blk|
            opts = args.pop.merge(opts) if args.last.is_a?(Hash)
            starts << { args: args, opts: opts }
            blk ? blk.call(connection) : connection
          end
        end

        def with_start(fake_start)
          original = Net::HTTP.method(:start)
          Net::HTTP.define_singleton_method(:start, &fake_start)
          begin
            yield
          ensure
            Net::HTTP.define_singleton_method(:start, original)
          end
        end
      end
    end
  end
end
