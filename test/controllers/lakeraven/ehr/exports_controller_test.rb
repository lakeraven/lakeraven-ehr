# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module ExportControllerEndToEndTestHelper
      EXPORT_TEST_PATIENT_DFN = "1"
      EXPECTED_NON_NDJSON_FILE_NAMES = %w[audit_log.csv configuration.json manifest.json].freeze

      private

      def kickoff_and_fetch_completed_export
        post "/lakeraven-ehr/exports",
          params: { export_type: "patient", patient_dfn: EXPORT_TEST_PATIENT_DFN },
          headers: @headers
        assert_response :accepted
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
        assert_response :ok
        [ export_id, JSON.parse(response.body) ]
      end

      def export_file_name_from_url(url)
        File.basename(URI.parse(url).path)
      end

      def assert_manifest_file_downloadable!(export_id, entry)
        file_name = export_file_name_from_url(entry.fetch("url"))
        get "/lakeraven-ehr/exports/#{export_id}/files/#{file_name}", headers: @headers
        assert_response :ok, "Expected 200 for manifest entry type=#{entry['type']} file=#{file_name}"

        if file_name.end_with?(".ndjson")
          assert_equal "application/fhir+ndjson", response.media_type
          response.body.each_line do |line|
            next if line.strip.empty?

            JSON.parse(line)
          end
        elsif file_name == "audit_log.csv"
          assert_equal "text/csv", response.media_type
          assert_equal EhiExportService.audit_csv_header_line, response.body.lines.first.to_s.chomp
        elsif file_name.end_with?(".json")
          assert_equal "application/json", response.media_type
          parsed = JSON.parse(response.body)
          assert_kind_of Hash, parsed
        else
          flunk "Unexpected non-NDJSON manifest entry type=#{entry['type']} file=#{file_name}"
        end
      end

      def assert_patient_file_includes_seeded_dfn!(export_id, manifest_body)
        patient_entry = manifest_body.fetch("output").find { |file| file["type"] == "Patient" }
        assert patient_entry, "Expected Patient manifest entry"

        file_name = export_file_name_from_url(patient_entry.fetch("url"))
        get "/lakeraven-ehr/exports/#{export_id}/files/#{file_name}", headers: @headers
        assert_response :ok

        patient_resources = response.body.each_line.filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        end
        matching = patient_resources.find do |resource|
          resource["resourceType"] == "Patient" && resource["id"].to_s == EXPORT_TEST_PATIENT_DFN
        end
        assert matching, "Expected Patient NDJSON for DFN #{EXPORT_TEST_PATIENT_DFN}"
      end
    end

    class ExportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include ExportControllerEndToEndTestHelper

      setup do
        # A bulk export is a state-changing operation and needs write scope;
        # these used to pass on the default read-only token.
        setup_smart_auth(scopes: "system/*.read system/*.write")
        ExportsController.reset_store!
        assert Patient.find_by_dfn(EXPORT_TEST_PATIENT_DFN),
          "Expected patient DFN #{EXPORT_TEST_PATIENT_DFN} from BASELINE_MOCK_SEEDS in test/test_helper.rb"
      end

      teardown do
        teardown_smart_auth
        ExportsController.reset_store!
      end

      test "POST /exports creates an export and returns 202" do
        post "/lakeraven-ehr/exports", headers: @headers
        assert_response :accepted
      end

      test "GET /exports/:id returns 404 for nonexistent export" do
        get "/lakeraven-ehr/exports/nonexistent", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "GET /exports/:id returns export status" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
        # 200 = completed, 202 = processing, 500 = failed (no test patient data)
        assert_includes [ 200, 202, 500 ], response.status
      end

      test "DELETE /exports/:id cancels export" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        delete "/lakeraven-ehr/exports/#{export_id}", headers: @headers
        assert_response :accepted
      end

      test "DELETE /exports/:id returns 404 for nonexistent" do
        delete "/lakeraven-ehr/exports/nonexistent", headers: @headers
        assert_response :not_found
      end

      test "exports require auth" do
        post "/lakeraven-ehr/exports"
        assert_response :unauthorized
      end

      test "export status requires auth" do
        get "/lakeraven-ehr/exports/test"
        assert_response :unauthorized
      end

      test "export cancel requires auth" do
        delete "/lakeraven-ehr/exports/test"
        assert_response :unauthorized
      end

      test "POST /exports with _type containing leading space either exports Patient or is refused 400" do
        post "/lakeraven-ehr/exports", params: { _type: [ " Patient" ] }, headers: @headers

        if response.status == 400
          assert_response :bad_request
        else
          assert_response :accepted
          export_id = JSON.parse(response.body)["id"]

          get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
          assert_response :ok
          body = JSON.parse(response.body)
          has_patient = body["output"]&.any? { |f| f["type"] == "Patient" }
          assert has_patient, "Expected manifest to list Patient's NDJSON if not 400"
        end
      end

      test "completed export shows output files" do
        _export_id, body = kickoff_and_fetch_completed_export

        assert body["output"].present?, "Expected non-empty output in completed export"
        assert body["transactionTime"].present?, "Expected transactionTime in completed export"
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        post "/lakeraven-ehr/exports",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end
    end

    class ExportFilesControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include ExportControllerEndToEndTestHelper

      setup do
        # A bulk export is a state-changing operation and needs write scope;
        # these used to pass on the default read-only token.
        setup_smart_auth(scopes: "system/*.read system/*.write")
        ExportsController.reset_store!
        assert Patient.find_by_dfn(EXPORT_TEST_PATIENT_DFN),
          "Expected patient DFN #{EXPORT_TEST_PATIENT_DFN} from BASELINE_MOCK_SEEDS in test/test_helper.rb"
      end

      teardown do
        teardown_smart_auth
        ExportsController.reset_store!
      end

      test "GET /exports/:id/files/:name returns file content" do
        export_id, body = kickoff_and_fetch_completed_export

        output = body.fetch("output")
        non_ndjson = output.reject { |entry| export_file_name_from_url(entry.fetch("url")).end_with?(".ndjson") }
        non_ndjson_names = non_ndjson.map { |entry| export_file_name_from_url(entry.fetch("url")) }
        assert_equal EXPECTED_NON_NDJSON_FILE_NAMES.sort, non_ndjson_names.sort,
          "Expected exactly #{EXPECTED_NON_NDJSON_FILE_NAMES.join(', ')} as non-NDJSON manifest entries"

        output.each do |entry|
          assert_manifest_file_downloadable!(export_id, entry)
        end

        assert_patient_file_includes_seeded_dfn!(export_id, body)
      end

      test "GET /exports/:id/files/:name returns 404 for nonexistent export" do
        get "/lakeraven-ehr/exports/nonexistent/files/data.ndjson", headers: @headers
        assert_response :not_found
      end

      test "GET /exports/:id/files/:name returns 404 for nonexistent file" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/exports/#{export_id}/files/nonexistent.ndjson", headers: @headers
        assert_response :not_found
      end

      test "export files require auth" do
        get "/lakeraven-ehr/exports/test/files/data.ndjson"
        assert_response :unauthorized
      end
    end
  end
end
