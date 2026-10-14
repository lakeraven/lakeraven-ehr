# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # lakeraven-ehr#553: a system/ token is bound to an organization at mint
    # time, and nothing in the FHIR read path consults that binding.
    #
    # The token endpoint's single-organization guard keeps a second
    # organization from minting today, so these tests create tokens directly.
    # That models the state the guard exists to prevent: a deployment that
    # reaches more than one organization once the broker connection is no
    # longer process-global (rpms-rpc#234), or a token minted before a second
    # organization registered.
    class OrganizationBoundaryTest < ActionDispatch::IntegrationTest
      setup do
        @home_app = bound_app("example-organization-a")
        @other_app = bound_app("example-organization-b")
      end

      teardown do
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      test "a token bound to the organization that owns the patient reads it" do
        get "/lakeraven-ehr/Patient/1", headers: bearer(@home_app)

        assert_response :ok
      end

      test "a token bound to another organization is refused that organization's patient" do
        skip "#553: no read-side organization boundary exists yet; remove this skip with the fix"
        get "/lakeraven-ehr/Patient/1", headers: bearer(@other_app)

        refute_equal 200, response.status,
          "a system/ token for organization B must not read organization A's patient"
        refute_includes response.body, "Anderson",
          "the refusal must not carry the patient's demographics"
      end

      private

      def bound_app(organization_id)
        Doorkeeper::Application.create!(
          name: "Backend #{organization_id}",
          uid: "backend-#{organization_id}",
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "system/*.read",
          confidential: true,
          organization_id: organization_id
        )
      end

      def bearer(app)
        token = Doorkeeper::AccessToken.create!(
          application: app, scopes: "system/*.read", expires_in: 300
        )
        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end
    end
  end
end
