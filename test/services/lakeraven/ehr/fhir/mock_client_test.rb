# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      # The engine's seeded FHIR test double (#599): the behaviour the
      # rpms-rpc mock had, under the engine's own name.
      class MockClientTest < ActiveSupport::TestCase
        setup do
          @client = MockClient.new
          @client.seed_resource("Patient", "1", {
            resourceType: "Patient", id: "1",
            name: [ { family: "Testpatient", given: [ "Ada" ] } ],
            identifier: [ { system: "urn:example:mrn", value: "MRN-0001" } ],
            gender: "female", birthDate: "1980-05-15"
          })
          @client.seed_resource("Patient", "2", {
            "resourceType" => "Patient", "id" => "2",
            "name" => [ { "family" => "Sampleperson", "given" => [ "Grace", "Test" ] } ],
            "identifier" => [ { "system" => "urn:example:mrn", "value" => "MRN-0002" } ],
            "gender" => "male", "birthDate" => "1975-01-02"
          })
          @client.seed_resource("Observation", "10", {
            resourceType: "Observation", id: "10", status: "final",
            subject: { reference: "Patient/1" }
          })
          @client.seed_resource("Observation", "11", {
            resourceType: "Observation", id: "11", status: "final",
            subject: { reference: "Patient/2" }
          })
          @client.seed_resource("Observation", "12", {
            resourceType: "Observation", id: "12", status: "final",
            subject: { reference: "2" }
          })
        end

        # --- read -----------------------------------------------------------

        test "read returns the seeded resource with string keys at every level" do
          patient = @client.read("Patient", "1")

          assert_equal "Patient", patient["resourceType"]
          assert_equal "1", patient["id"]
          assert_equal "Testpatient", patient["name"].first["family"]
          assert_equal [ "Ada" ], patient["name"].first["given"]
          assert_equal "MRN-0001", patient["identifier"].first["value"]
          assert patient.keys.all?(String)
          assert patient["name"].first.keys.all?(String)
        end

        test "read accepts an Integer id and an Integer seed id" do
          @client.seed_resource("Patient", 3, { resourceType: "Patient", id: "3" })

          assert_equal "1", @client.read("Patient", 1)["id"]
          assert_equal "3", @client.read("Patient", "3")["id"]
        end

        test "read of an unseeded id returns a not-found OperationOutcome" do
          outcome = @client.read("Patient", "999")

          assert_equal "OperationOutcome", outcome["resourceType"]
          issue = outcome["issue"].first
          assert_equal "error", issue["severity"]
          assert_equal "not-found", issue["code"]
          assert_includes issue["diagnostics"], "Patient/999"
        end

        test "read of an unseeded resource type returns a not-found OperationOutcome" do
          outcome = @client.read("Practitioner", "1")

          assert_equal "OperationOutcome", outcome["resourceType"]
          assert_equal "not-found", outcome["issue"].first["code"]
        end

        test "mutating a read result does not change the seeded resource" do
          first = @client.read("Patient", "1")
          first["gender"] = "unknown"
          first["name"].first["family"] = "Changed"
          first["name"].first["given"] << "Extra"
          first["identifier"].clear

          again = @client.read("Patient", "1")
          assert_equal "female", again["gender"]
          assert_equal "Testpatient", again["name"].first["family"]
          assert_equal [ "Ada" ], again["name"].first["given"]
          assert_equal "MRN-0001", again["identifier"].first["value"]
        end

        test "mutating a search result does not change the seeded resource" do
          entry = @client.search("Patient", _id: "2")["entry"].first["resource"]
          entry["name"].first["given"] << "Extra"

          assert_equal [ "Grace", "Test" ], @client.read("Patient", "2")["name"].first["given"]
        end

        test "seeding the same id again replaces the resource" do
          @client.seed_resource("Patient", "1", { resourceType: "Patient", id: "1", gender: "other" })

          assert_equal "other", @client.read("Patient", "1")["gender"]
        end

        # --- search: bundle shape -------------------------------------------

        test "search with no params returns a searchset Bundle of every resource of the type" do
          bundle = @client.search("Patient")

          assert_equal "Bundle", bundle["resourceType"]
          assert_equal "searchset", bundle["type"]
          assert_equal 2, bundle["total"]
          assert_equal %w[1 2], ids(bundle)
          assert bundle["entry"].all? { |e| e["resource"].keys.all?(String) }
        end

        test "search of an unseeded type returns an empty Bundle" do
          bundle = @client.search("Practitioner", name: "Testpatient")

          assert_equal "Bundle", bundle["resourceType"]
          assert_equal "searchset", bundle["type"]
          assert_equal 0, bundle["total"]
          assert_equal [], bundle["entry"]
        end

        # --- search: filters ------------------------------------------------

        test "name matches a family prefix, case-insensitively" do
          assert_equal %w[1], ids(@client.search("Patient", name: "testp"))
          assert_equal %w[2], ids(@client.search("Patient", name: "SAMPLE"))
        end

        test "name matches a given name contained in 'family given'" do
          assert_equal %w[1], ids(@client.search("Patient", name: "ada"))
          assert_equal %w[2], ids(@client.search("Patient", name: "Sampleperson Grace"))
        end

        test "name that matches nothing returns an empty Bundle" do
          bundle = @client.search("Patient", name: "Zzzz")

          assert_equal 0, bundle["total"]
          assert_equal [], bundle["entry"]
        end

        test "identifier matches the identifier value exactly" do
          assert_equal %w[2], ids(@client.search("Patient", identifier: "MRN-0002"))
          assert_equal [], ids(@client.search("Patient", identifier: "MRN-000"))
        end

        test "patient matches a Patient/<id> subject reference" do
          assert_equal %w[10], ids(@client.search("Observation", patient: "1"))
        end

        test "patient matches a bare-id subject reference too" do
          assert_equal %w[11 12], ids(@client.search("Observation", patient: "2"))
        end

        test "_id matches the resource id" do
          assert_equal %w[2], ids(@client.search("Patient", _id: "2"))
          assert_equal %w[1], ids(@client.search("Patient", "_id" => 1))
        end

        test "gender matches exactly" do
          assert_equal %w[1], ids(@client.search("Patient", gender: "female"))
          assert_equal %w[2], ids(@client.search("Patient", gender: "male"))
        end

        test "birthdate matches birthDate exactly" do
          assert_equal %w[2], ids(@client.search("Patient", birthdate: "1975-01-02"))
          assert_equal [], ids(@client.search("Patient", birthdate: "1975"))
        end

        test "every param must match" do
          assert_equal %w[1], ids(@client.search("Patient", name: "Testpatient", gender: "female"))
          assert_equal [], ids(@client.search("Patient", name: "Testpatient", gender: "male"))
        end

        test "an unknown param does not filter" do
          assert_equal %w[1 2], ids(@client.search("Patient", _lastUpdated: "gt2020-01-01"))
          assert_equal %w[1], ids(@client.search("Patient", gender: "female", _count: "50"))
        end

        # --- independence from rpms-rpc --------------------------------------

        test "is not the rpms-rpc mock" do
          refute_equal "RpmsRpc", MockClient.name.split("::").first
          assert_equal "Lakeraven::EHR::FHIR::MockClient", MockClient.name
        end

        private

        def ids(bundle)
          bundle["entry"].map { |e| e["resource"]["id"] }
        end
      end
    end
  end
end
