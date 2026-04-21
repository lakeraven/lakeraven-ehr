# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class LaunchContextTest < ActiveSupport::TestCase
      setup do
        @app = Doorkeeper::Application.create!(
          name: "test", redirect_uri: "https://example.test/callback",
          scopes: "launch patient/Patient.read", confidential: true
        )
      end

      teardown do
        LaunchContext.delete_all
        Doorkeeper::Application.delete_all
      end

      test "mint creates a launch context with a token" do
        ctx = LaunchContext.mint(
          oauth_application_uid: @app.uid,
          patient_dfn: "1",
          facility_identifier: "fac_main"
        )

        assert ctx.persisted?
        assert ctx.launch_token.present?
        assert_equal @app.uid, ctx.oauth_application_uid
        assert_equal "1", ctx.patient_dfn
        assert_equal "fac_main", ctx.facility_identifier
      end

      test "launch_token starts with lc_ prefix" do
        ctx = LaunchContext.mint(
          oauth_application_uid: @app.uid,
          patient_dfn: "1"
        )

        assert ctx.launch_token.start_with?("lc_")
      end

      test "resolve finds a valid launch context by token" do
        ctx = LaunchContext.mint(
          oauth_application_uid: @app.uid,
          patient_dfn: "1"
        )

        found = LaunchContext.resolve(ctx.launch_token)
        assert_equal ctx.id, found.id
        assert_equal "1", found.patient_dfn
      end

      test "resolve returns nil for unknown token" do
        assert_nil LaunchContext.resolve("lc_nonexistent")
      end

      test "resolve returns nil for expired token" do
        ctx = LaunchContext.mint(
          oauth_application_uid: @app.uid,
          patient_dfn: "1",
          ttl: 1.minute
        )

        travel 2.minutes
        assert_nil LaunchContext.resolve(ctx.launch_token)
      ensure
        travel_back
      end

      test "patient_dfn is optional" do
        ctx = LaunchContext.mint(oauth_application_uid: @app.uid)

        assert ctx.persisted?
        assert_nil ctx.patient_dfn
      end

      test "token response includes patient when launch resolves" do
        ctx = LaunchContext.mint(
          oauth_application_uid: @app.uid,
          patient_dfn: "42"
        )

        smart_context = ctx.to_smart_context
        assert_equal "42", smart_context[:patient]
      end

      test "token response omits patient when no patient_dfn" do
        ctx = LaunchContext.mint(oauth_application_uid: @app.uid)

        smart_context = ctx.to_smart_context
        refute smart_context.key?(:patient)
      end
    end
  end
end
