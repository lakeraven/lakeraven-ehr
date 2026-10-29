# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class GroupsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      MOUNT = "/lakeraven-ehr"
      GROUP_ID = "cohort-synthetic-a"
      EMPTY_GROUP_ID = "cohort-synthetic-empty"
      UNKNOWN_GROUP_ID = "cohort-synthetic-unknown"
      MIXED_GROUP_ID = "cohort-synthetic-mixed"
      SOLO_PATIENT_GROUP_ID = "cohort-synthetic-solo-patient"
      DFN_A = "900001"
      DFN_B = "900002"
      DFN_C = "900003"
      DOTTED_COHORT_A = "a"
      DOTTED_COHORT_AB = "a.b"
      DOTTED_DFN_A = "900005"
      DOTTED_DFN_AB = "900009"
      NOT_FOUND_DIAGNOSTICS = "Group not found"
      INSUFFICIENT_PATIENT_SCOPE = "Insufficient scope for reading Patient"
      FHIR_GROUP_MEMBERS_TABLE = "lakeraven_ehr_fhir_group_members"

      setup do
        ::Lakeraven::EHR::FhirGroupMember.delete_all
        seed_group!(GROUP_ID, [ DFN_C, DFN_A, DFN_B ])
        seed_group!(MIXED_GROUP_ID, [ DFN_A, DFN_B ])
        seed_group!(SOLO_PATIENT_GROUP_ID, [ DFN_A ])

        AuditEvent.delete_all
        setup_smart_auth(scopes: "system/Group.read system/Patient.read")
      end

      teardown do
        AuditEvent.delete_all
        teardown_smart_auth
      end

      test "GET /Group/:id returns FHIR Group with member Patient references" do
        get group_path(GROUP_ID), headers: @headers

        assert_response :ok
        assert_equal "application/fhir+json", response.media_type

        body = JSON.parse(response.body)
        assert_equal "Group", body["resourceType"]
        assert_equal GROUP_ID, body["id"]
        assert_equal "person", body["type"]
        assert_equal true, body["actual"]
        assert_equal 3, body["quantity"]
        assert_equal(
          [ { "entity" => { "reference" => "Patient/#{DFN_A}" } },
            { "entity" => { "reference" => "Patient/#{DFN_B}" } },
            { "entity" => { "reference" => "Patient/#{DFN_C}" } } ],
          body["member"]
        )
      end

      test "member references follow patient_dfn order from members_of" do
        get group_path(GROUP_ID), headers: @headers

        references = JSON.parse(response.body).fetch("member").map { |m| m.dig("entity", "reference") }
        assert_equal references.sort, references
      end

      test "quantity matches member count" do
        get group_path(GROUP_ID), headers: @headers

        body = JSON.parse(response.body)
        assert_equal body["member"].length, body["quantity"]
      end

      test "unknown group id returns 404 OperationOutcome without echoing the id" do
        get group_path(UNKNOWN_GROUP_ID), headers: @headers

        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
        assert_equal NOT_FOUND_DIAGNOSTICS, body["issue"].first["diagnostics"]
        refute_includes body["issue"].first["diagnostics"].to_s, UNKNOWN_GROUP_ID
      end

      test "group with no members returns the same not-found response as an unknown group" do
        get group_path(EMPTY_GROUP_ID), headers: @headers
        empty = [ response.status, JSON.parse(response.body) ]

        get group_path(UNKNOWN_GROUP_ID), headers: @headers
        unknown = [ response.status, JSON.parse(response.body) ]

        assert_equal empty.first, unknown.first
        assert_equal empty.last.dig("issue", 0, "diagnostics"),
                     unknown.last.dig("issue", 0, "diagnostics")
        refute_includes empty.last.dig("issue", 0, "diagnostics").to_s, EMPTY_GROUP_ID
      end

      test "requires authentication" do
        get group_path(GROUP_ID)

        assert_response :unauthorized
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "login", body["issue"].first["code"]
        refute_includes response.body, "Patient/#{DFN_A}"
      end

      test "token without Group read scope returns 403 and discloses nothing" do
        setup_smart_auth(scopes: "system/Patient.read")

        get group_path(GROUP_ID), headers: @headers

        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "forbidden", body["issue"].first["code"]
        refute_includes response.body, "Patient/#{DFN_A}"
      end

      test "token without Patient read scope returns 403 and discloses nothing" do
        setup_smart_auth(scopes: "system/Group.read")

        get group_path(GROUP_ID), headers: @headers

        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "forbidden", body["issue"].first["code"]
        assert_equal INSUFFICIENT_PATIENT_SCOPE, body["issue"].first["diagnostics"]
        refute_includes response.body, "Patient/#{DFN_A}"
      end

      test "Group.read without Patient.read answers the same 403 for existing, unknown, and empty cohorts without querying membership" do
        setup_smart_auth(scopes: "system/Group.read")

        responses = []
        membership_sql = capture_fhir_group_member_sql do
          [ GROUP_ID, UNKNOWN_GROUP_ID, EMPTY_GROUP_ID ].each do |group_id|
            get group_path(group_id), headers: @headers
            responses << [ response.status, response.body ]
          end
        end

        assert_empty membership_sql,
                     "authorization must run before any #{FHIR_GROUP_MEMBERS_TABLE} query"
        assert responses.all? { |status, _| status == 403 }, responses.inspect
        assert_equal 1, responses.map(&:last).uniq.length, "expected identical response bodies"
        body = JSON.parse(responses.first.last)
        assert_equal "forbidden", body["issue"].first["code"]
        assert_equal INSUFFICIENT_PATIENT_SCOPE, body["issue"].first["diagnostics"]
        responses.each do |_, raw_body|
          refute_includes raw_body, "Patient/#{DFN_A}"
          refute_includes raw_body, NOT_FOUND_DIAGNOSTICS
        end
      end

      test "patient-bound token is refused for every Group read with identical 403 and no cohort query" do
        headers = patient_bound_group_headers(DFN_A)
        targets = [ UNKNOWN_GROUP_ID, SOLO_PATIENT_GROUP_ID, MIXED_GROUP_ID ]

        responses = []
        membership_sql = capture_fhir_group_member_sql do
          targets.each do |group_id|
            get group_path(group_id), headers: headers
            responses << [ response.status, response.body ]
          end
        end

        assert_empty membership_sql,
                     "patient-bound Group read must be refused before #{FHIR_GROUP_MEMBERS_TABLE} is queried"
        assert responses.all? { |status, _| status == 403 }, responses.inspect
        assert_equal 1, responses.map(&:last).uniq.length, "expected identical response bodies"
        body = JSON.parse(responses.first.last)
        assert_equal "forbidden", body["issue"].first["code"]
        responses.each do |_, raw_body|
          refute_includes raw_body, "Patient/#{DFN_B}"
          refute_includes raw_body, "Patient/#{DFN_A}"
        end
      end

      test "GET /Group/a.b returns the dotted cohort, not the prefix cohort" do
        seed_group!(DOTTED_COHORT_A, [ DOTTED_DFN_A ])
        seed_group!(DOTTED_COHORT_AB, [ DOTTED_DFN_AB ])

        get group_path(DOTTED_COHORT_AB), headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal DOTTED_COHORT_AB, body["id"]
        assert_equal(
          [ { "entity" => { "reference" => "Patient/#{DOTTED_DFN_AB}" } } ],
          body["member"]
        )
        refute_includes body["member"].to_s, DOTTED_DFN_A
      end

      test "Group ids ending in .xml or .json are literal cohort ids, not content formats" do
        %w[cohort-a.xml cohort-a.json].each do |requested_id|
          AuditEvent.delete_all

          get group_path(requested_id), headers: @headers

          assert_response :not_found, requested_id
          body = JSON.parse(response.body)
          assert_equal NOT_FOUND_DIAGNOSTICS, body["issue"].first["diagnostics"]

          event = AuditEvent.recent.first
          assert_equal requested_id, event.entity_identifier, requested_id
        end
      end

      test "successful GET produces an AuditEvent for the Group" do
        assert_difference -> { AuditEvent.count }, 1 do
          get group_path(GROUP_ID), headers: @headers
        end

        event = AuditEvent.recent.first
        assert_equal "rest", event.event_type
        assert_equal "R", event.action
        assert_equal "0", event.outcome
        assert_equal "Group", event.entity_type
        assert_equal GROUP_ID, event.entity_identifier
        assert_equal "Application", event.agent_who_type
        assert_equal @oauth_app.uid, event.agent_who_identifier
      end

      test "404 response produces an AuditEvent with minor-failure outcome" do
        assert_difference -> { AuditEvent.count }, 1 do
          get group_path(UNKNOWN_GROUP_ID), headers: @headers
        end

        event = AuditEvent.recent.first
        assert_equal "4", event.outcome
      end

      test "403 scope refusal produces an AuditEvent and discloses nothing" do
        setup_smart_auth(scopes: "openid")

        assert_difference -> { AuditEvent.count }, 1 do
          get group_path(GROUP_ID), headers: @headers
        end

        assert_response :forbidden
        refute_includes response.body, "Patient/#{DFN_A}"
        event = AuditEvent.recent.first
        assert_equal "4", event.outcome
      end

      test "invalid Group id is refused before members_of is queried" do
        invalid_id = "a" * 65
        calls = track_members_of_calls do
          get group_path(invalid_id), headers: @headers
        end

        assert_response :not_found
        assert_empty calls, "overlong id must not reach FhirGroupMember.members_of"
        body = JSON.parse(response.body)
        assert_equal NOT_FOUND_DIAGNOSTICS, body["issue"].first["diagnostics"]
        refute_includes body["issue"].first["diagnostics"].to_s, invalid_id
      end

      test "Group id with illegal characters is refused before members_of is queried" do
        invalid_id = "cohort|invalid"
        calls = track_members_of_calls do
          get group_path(CGI.escape(invalid_id)), headers: @headers
        end

        assert_response :not_found
        assert_empty calls
      end

      private

      def group_path(id)
        "#{MOUNT}/Group/#{id}"
      end

      def seed_group!(group_id, dfns)
        dfns.each do |dfn|
          ::Lakeraven::EHR::FhirGroupMember.create!(group_id: group_id, patient_dfn: dfn)
        end
      end

      def track_members_of_calls
        calls = []
        original = ::Lakeraven::EHR::FhirGroupMember.method(:members_of)
        ::Lakeraven::EHR::FhirGroupMember.singleton_class.define_method(:members_of) do |group_id|
          calls << group_id
          original.call(group_id)
        end
        yield
        calls
      ensure
        ::Lakeraven::EHR::FhirGroupMember.singleton_class.define_method(:members_of, original)
      end

      def capture_fhir_group_member_sql
        statements = []
        callback = lambda do |*_, payload|
          sql = payload[:sql].to_s
          statements << sql if sql.include?(FHIR_GROUP_MEMBERS_TABLE)
        end

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          yield
        end

        statements
      end

      def patient_bound_group_headers(patient_dfn)
        app = Doorkeeper::Application.create!(
          name: "patient-group-test-#{SecureRandom.hex(4)}",
          redirect_uri: "https://example.test/callback",
          scopes: "patient/Group.read patient/Patient.read",
          confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: app,
          scopes: "patient/Group.read patient/Patient.read",
          resource_owner_id: patient_dfn,
          expires_in: 3600
        )
        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end
    end
  end
end
