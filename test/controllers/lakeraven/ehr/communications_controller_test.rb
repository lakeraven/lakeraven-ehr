# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Demo prototype (#988): a registered outside app posts a referral
    # follow-up as a FHIR Communication. It is held for review, audited, and
    # nothing is written to RPMS. Synthetic patient and referral; mock broker.
    class CommunicationsControllerTest < ActionDispatch::IntegrationTest
      include RcisFollowUpMock

      DFN = 3
      IEN = 7001
      CLIENT_ID = "outside-app-demo"

      setup do
        @outside_app = Doorkeeper::Application.create!(name: "Stand-in outreach app", uid: CLIENT_ID,
                                               redirect_uri: "urn:ietf:wg:oauth:2.0:oob", confidential: true,
                                               scopes: "system/ServiceRequest.r system/Communication.cr")
        seed_open_referral(dfn: DFN, ien: IEN)
      end

      teardown do
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      def headers(scopes = "system/ServiceRequest.r system/Communication.cr", app: @outside_app)
        token = Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: 3600)
        { "Authorization" => "Bearer #{token.plaintext_token || token.token}", "Content-Type" => "application/fhir+json" }
      end

      def communication(overrides = {})
        {
          resourceType: "Communication",
          status: "completed",
          meta: { tag: [ { system: "http://terminology.hl7.org/CodeSystem/v3-ObservationValue", code: "AIAST" } ] },
          subject: { reference: "Patient/#{DFN}" },
          about: [ { reference: "ServiceRequest/#{DFN}-#{IEN}" } ],
          sender: { reference: "Device/#{CLIENT_ID}" },
          payload: [ { contentString: "Patient says the cardiology appointment is booked for 12/4." } ],
          extension: [ { url: AppFollowUp::EXTENSION, extension: [
            { url: "reached", valueBoolean: true }, { url: "appointmentDate", valueDate: "2026-12-04" }
          ] } ]
        }.merge(overrides)
      end

      def post_communication(body, hdrs = headers)
        post "/lakeraven-ehr/Communication", params: body.to_json, headers: hdrs
      end

      test "a follow-up about the patient's referral is held for review, audited, and nothing goes to RPMS" do
        assert_difference -> { AppFollowUp.count } => 1 do
          post_communication(communication)
        end

        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Communication", body["resourceType"]
        assert_equal "in-progress", body["status"], "held for review, not completed"
        assert_equal "AIAST", body.dig("meta", "tag", 0, "code")
        follow_up = AppFollowUp.last
        assert follow_up.pending?
        assert follow_up.ai_generated
        assert_equal [ DFN, IEN, Date.new(2026, 12, 4), true ], [ follow_up.patient_dfn, follow_up.referral_ien, follow_up.appointment_on, follow_up.reached ]
        assert_match %r{/Communication/#{follow_up.id}\z}, response.headers["Location"]
        audit = AuditEvent.where(event_type: "application", action: "C").last
        assert_equal [ "Patient", DFN.to_s, CLIENT_ID ], [ audit.entity_type, audit.entity_identifier, audit.agent_who_identifier ]
        assert_match(/RPMS referral #{IEN}/, audit.outcome_desc)
        refute_match(/cardiology/i, audit.outcome_desc, "the free-text summary stays out of the audit row")
        assert_empty bmc_update_calls, "nothing is written to RPMS when a follow-up is posted"
      end

      test "a token without Communication create is refused" do
        post_communication(communication, headers("system/ServiceRequest.r system/Communication.r"))
        assert_response :forbidden
        assert_equal 0, AppFollowUp.count
      end

      test "a token that cannot read the ServiceRequest is refused" do
        post_communication(communication, headers("system/Communication.cr"))
        assert_response :forbidden
        assert_equal 0, AppFollowUp.count
      end

      test "other shapes are refused with an OperationOutcome" do
        {
          "not a Communication" => communication(resourceType: "Observation"),
          "no patient" => communication(subject: { reference: "Group/1" }),
          "two referrals" => communication(about: [ { reference: "ServiceRequest/#{DFN}-#{IEN}" }, { reference: "ServiceRequest/#{DFN}-1" } ]),
          "a bare referral IEN" => communication(about: [ { reference: "ServiceRequest/#{IEN}" } ]),
          "another patient's id form" => communication(about: [ { reference: "ServiceRequest/1-#{IEN}" } ]),
          "another sender" => communication(sender: { reference: "Device/someone-else" }),
          "an attachment" => communication(payload: [ { contentAttachment: { contentType: "audio/wav" } } ]),
          "a long summary" => communication(payload: [ { contentString: "x" * 501 } ]),
          "a referral the patient does not have" => communication(about: [ { reference: "ServiceRequest/#{DFN}-9999" } ]),
          "a bad date" => communication(extension: [ { url: AppFollowUp::EXTENSION, extension: [ { url: "appointmentDate", valueDate: "12/4" } ] } ])
        }.each do |label, body|
          post_communication(body)
          assert_response :unprocessable_content, label
          assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"], label
        end
        assert_equal 0, AppFollowUp.count
      end

      test "the app reads back what became of it, and another app cannot" do
        post_communication(communication)
        id = JSON.parse(response.body)["id"]
        AppFollowUp.find(id).update!(status: "rejected", reviewed_by_name: "PROFILE,MD", reviewed_at: Time.current)

        get "/lakeraven-ehr/Communication/#{id}", headers: headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "not-done", body["status"]
        assert_equal "Rejected in staff review", body.dig("statusReason", "text")

        other = Doorkeeper::Application.create!(name: "Other app", uid: "other-app", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
                                                confidential: true, scopes: "system/Communication.r")
        get "/lakeraven-ehr/Communication/#{id}", headers: headers("system/Communication.r", app: other)
        assert_response :not_found
      end
    end
  end
end
