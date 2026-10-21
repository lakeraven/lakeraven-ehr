# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # lakeraven-ehr#553: a system/ token is bound to an organization at mint
    # time, and nothing in the FHIR read path consults that binding.
    #
    # This file pins the OUTCOME only: when reads honor the token's tenant,
    # a token for one organization must not read a Patient id that another
    # organization's token can read on the same route.
    #
    # Fixtures give Patient 1 no organization; ADR 0007 rejects writing
    # organization filters against fabricated fixtures, so un-skipping the
    # paired test here is necessary but NOT sufficient to close #553.
    # Acceptance for #553 must also add a fixture where two tenants share
    # ONE mock instance — the case connection selection alone cannot separate.
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

      test "control: system/ token reads Patient/1 on the same route and scope as the paired refusal test" do
        # Same GET and bearer shape as the paired test's first leg. A refusal in
        # the paired test cannot be blamed on the route or scope alone.
        # Fixtures do not tie Patient/1 to example-organization-a; this does not
        # show the token's organization owns the patient.
        get "/lakeraven-ehr/Patient/1", headers: bearer(@home_app)

        assert_response :ok
      end

      test "a token bound to one organization is refused a patient read that a token bound to a different organization can make" do
        skip "#553: no read-side organization boundary exists yet; remove this skip with the fix"

        get "/lakeraven-ehr/Patient/1", headers: bearer(@home_app)
        assert_response :ok

        get "/lakeraven-ehr/Patient/1", headers: bearer(@other_app)
        assert_includes [ 403, 404 ], response.status,
          "only the organization binding differs; 401 or 5xx do not prove tenancy refusal"
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
