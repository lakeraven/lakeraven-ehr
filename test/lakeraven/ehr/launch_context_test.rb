# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::LaunchContextTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR::LaunchContext.delete_all
  end

  def base_args
    {
      tenant_identifier: "tnt_test",
      oauth_application_uid: "test-client-uid",
      patient_identifier: "pt_01H8X",
      facility_identifier: "fac_main"
    }
  end

  def resolve_args(launch_token, overrides = {})
    [ launch_token, { tenant_identifier: "tnt_test", oauth_application_uid: "test-client-uid" }.merge(overrides) ]
  end

  def resolve(launch_token, **overrides)
    Lakeraven::EHR::LaunchContext.resolve(
      launch_token,
      tenant_identifier: "tnt_test",
      oauth_application_uid: "test-client-uid",
      **overrides
    )
  end

  test "mint creates a persisted record with a launch_token" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert ctx.persisted?
    assert ctx.launch_token.present?
    assert ctx.launch_token.start_with?("lc_")
  end

  test "mint sets expires_at to ttl from now" do
    freeze = Time.utc(2026, 4, 7, 12, 0, 0)
    travel_to(freeze) do
      ctx = Lakeraven::EHR::LaunchContext.mint(**base_args, ttl: 5.minutes)
      assert_equal freeze + 5.minutes, ctx.expires_at
    end
  end

  test "mint defaults ttl to 10 minutes" do
    freeze = Time.utc(2026, 4, 7, 12, 0, 0)
    travel_to(freeze) do
      ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
      assert_equal freeze + 10.minutes, ctx.expires_at
    end
  end

  test "mint stores all binding fields" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args, encounter_identifier: "enc_01H8Y")
    assert_equal "tnt_test", ctx.tenant_identifier
    assert_equal "test-client-uid", ctx.oauth_application_uid
    assert_equal "pt_01H8X", ctx.patient_identifier
    assert_equal "fac_main", ctx.facility_identifier
    assert_equal "enc_01H8Y", ctx.encounter_identifier
  end

  test "resolve finds an active context by token + tenant + client" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert_equal ctx, resolve(ctx.launch_token)
  end

  test "resolve returns nil for unknown token" do
    assert_nil resolve("lc_unknown")
  end

  test "resolve returns nil for nil and empty launch_token" do
    assert_nil resolve(nil)
    assert_nil resolve("")
  end

  test "resolve returns nil for nil and empty tenant_identifier" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert_nil resolve(ctx.launch_token, tenant_identifier: nil)
    assert_nil resolve(ctx.launch_token, tenant_identifier: "")
  end

  test "resolve returns nil for nil and empty oauth_application_uid" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert_nil resolve(ctx.launch_token, oauth_application_uid: nil)
    assert_nil resolve(ctx.launch_token, oauth_application_uid: "")
  end

  test "resolve returns nil when the token belongs to a different tenant" do
    # Cross-tenant: a launch minted for tnt_test is not redeemable on
    # tnt_other's surface.
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert_nil resolve(ctx.launch_token, tenant_identifier: "tnt_other")
  end

  test "resolve returns nil when the token belongs to a different OAuth client" do
    # Cross-client: a launch minted for app A is not redeemable by app B
    # even within the same tenant. A leaked launch token is useless to
    # any other registered client.
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert_nil resolve(ctx.launch_token, oauth_application_uid: "different-client-uid")
  end

  test "resolve returns nil for an expired context" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args, ttl: 5.minutes)
    travel_to(Time.current + 6.minutes) do
      assert_nil resolve(ctx.launch_token)
    end
  end

  test "consume! marks the context consumed and resolve returns nil afterward" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert ctx.consume!
    assert ctx.reload.consumed_at.present?
    assert_nil resolve(ctx.launch_token)
  end

  test "consume! returns false on a second call (single-use guarantee)" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    assert ctx.consume!
    refute ctx.consume!
  end

  test "expired? returns true after ttl elapses" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args, ttl: 5.minutes)
    travel_to(Time.current + 6.minutes) do
      assert ctx.reload.expired?
    end
  end

  test "validation rejects records missing patient_identifier" do
    refute Lakeraven::EHR::LaunchContext.new(
      launch_token: "lc_x",
      tenant_identifier: "tnt_test",
      oauth_application_uid: "test-client-uid",
      expires_at: 10.minutes.from_now
    ).valid?
  end

  test "validation rejects records missing tenant_identifier" do
    refute Lakeraven::EHR::LaunchContext.new(
      launch_token: "lc_x",
      oauth_application_uid: "test-client-uid",
      patient_identifier: "pt_01H8X",
      expires_at: 10.minutes.from_now
    ).valid?
  end

  test "validation rejects records missing oauth_application_uid" do
    refute Lakeraven::EHR::LaunchContext.new(
      launch_token: "lc_x",
      tenant_identifier: "tnt_test",
      patient_identifier: "pt_01H8X",
      expires_at: 10.minutes.from_now
    ).valid?
  end

  test "launch_token uniqueness is enforced" do
    ctx = Lakeraven::EHR::LaunchContext.mint(**base_args)
    duplicate = Lakeraven::EHR::LaunchContext.new(
      launch_token: ctx.launch_token,
      patient_identifier: "pt_other",
      tenant_identifier: "tnt_test",
      oauth_application_uid: "test-client-uid",
      expires_at: 10.minutes.from_now
    )
    refute duplicate.valid?
  end

  test "minted launch_tokens are unique across calls" do
    tokens = 10.times.map { Lakeraven::EHR::LaunchContext.mint(**base_args).launch_token }
    assert_equal tokens.uniq.length, tokens.length
  end
end
