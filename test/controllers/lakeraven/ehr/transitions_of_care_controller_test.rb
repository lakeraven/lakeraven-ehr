# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TransitionsOfCareControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "POST /transitions_of_care generates C-CDA XML" do
        post "/lakeraven-ehr/transitions_of_care",
          params: {patient_dfn: "1"}, headers: @headers
        assert_response :created
        assert_equal "application/xml", response.media_type
        assert_includes response.body, "ClinicalDocument"
      end

      test "POST /transitions_of_care returns 404 for unknown patient" do
        post "/lakeraven-ehr/transitions_of_care",
          params: {patient_dfn: "99999"}, headers: @headers
        assert_response :not_found
      end

      test "POST /transitions_of_care includes patient demographics" do
        post "/lakeraven-ehr/transitions_of_care",
          params: {patient_dfn: "1"}, headers: @headers
        assert_includes response.body, "recordTarget"
        assert_includes response.body, "patientRole"
      end

      test "POST /transitions_of_care requires auth" do
        post "/lakeraven-ehr/transitions_of_care",
          params: {patient_dfn: "1"}
        assert_response :unauthorized
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        post "/lakeraven-ehr/transitions_of_care",
          params: {patient_dfn: "1"},
          headers: {"Authorization" => "Bearer #{expired.plaintext_token || expired.token}"}
        assert_response :unauthorized
      end
    end
  end
end
