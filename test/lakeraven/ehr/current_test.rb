# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::CurrentTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR::Current.reset!
  end

  teardown do
    Lakeraven::EHR::Current.reset!
  end

  test "tenant_identifier defaults to nil" do
    assert_nil Lakeraven::EHR::Current.tenant_identifier
  end

  test "facility_identifier defaults to nil" do
    assert_nil Lakeraven::EHR::Current.facility_identifier
  end

  test "tenant_identifier can be set and read" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    assert_equal "tnt_test", Lakeraven::EHR::Current.tenant_identifier
  end

  test "facility_identifier can be set and read" do
    Lakeraven::EHR::Current.facility_identifier = "fac_main"
    assert_equal "fac_main", Lakeraven::EHR::Current.facility_identifier
  end

  test "reset! clears both tenant and facility" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    Lakeraven::EHR::Current.facility_identifier = "fac_main"
    Lakeraven::EHR::Current.reset!
    assert_nil Lakeraven::EHR::Current.tenant_identifier
    assert_nil Lakeraven::EHR::Current.facility_identifier
  end

  test "with_tenant block sets and restores tenant_identifier" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_outer"
    Lakeraven::EHR::Current.with_tenant("tnt_inner") do
      assert_equal "tnt_inner", Lakeraven::EHR::Current.tenant_identifier
    end
    assert_equal "tnt_outer", Lakeraven::EHR::Current.tenant_identifier
  end

  test "with_tenant restores tenant even if block raises" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_outer"
    assert_raises(RuntimeError) do
      Lakeraven::EHR::Current.with_tenant("tnt_inner") do
        raise "boom"
      end
    end
    assert_equal "tnt_outer", Lakeraven::EHR::Current.tenant_identifier
  end

  test "MissingTenantContextError exists and inherits from StandardError" do
    assert Lakeraven::EHR::MissingTenantContextError < StandardError
  end
end
