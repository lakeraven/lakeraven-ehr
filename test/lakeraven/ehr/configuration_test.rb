# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::ConfigurationTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR.reset_configuration!
  end

  teardown do
    Lakeraven::EHR.reset_configuration!
  end

  test "configuration starts with no adapter" do
    assert_nil Lakeraven::EHR.configuration.adapter
  end

  test "configure block sets the adapter" do
    custom_adapter = Object.new
    Lakeraven::EHR.configure do |config|
      config.adapter = custom_adapter
    end
    assert_equal custom_adapter, Lakeraven::EHR.configuration.adapter
  end

  test "Lakeraven::EHR.adapter returns the configured adapter" do
    custom_adapter = Object.new
    Lakeraven::EHR.configure { |c| c.adapter = custom_adapter }
    assert_equal custom_adapter, Lakeraven::EHR.adapter
  end

  test "Lakeraven::EHR.adapter raises NotConfiguredError when no adapter is set" do
    Lakeraven::EHR.reset_configuration!
    error = assert_raises(Lakeraven::EHR::NotConfiguredError) do
      Lakeraven::EHR.adapter
    end
    assert_match(/not configured/i, error.message)
  end

  test "reset_configuration! clears the adapter" do
    Lakeraven::EHR.configure { |c| c.adapter = Object.new }
    Lakeraven::EHR.reset_configuration!
    assert_nil Lakeraven::EHR.configuration.adapter
  end

  # -- tenant_resolver / facility_resolver -----------------------------------

  class FakeRequest
    attr_reader :headers, :host
    def initialize(headers: {}, host: "example.com")
      @headers = headers
      @host = host
    end
  end

  test "default tenant_resolver reads X-Tenant-Identifier header" do
    request = FakeRequest.new(headers: { "X-Tenant-Identifier" => "tnt_from_header" })
    assert_equal "tnt_from_header", Lakeraven::EHR.configuration.tenant_resolver.call(request)
  end

  test "default tenant_resolver returns nil when header is missing" do
    request = FakeRequest.new(headers: {})
    assert_nil Lakeraven::EHR.configuration.tenant_resolver.call(request)
  end

  test "default tenant_resolver returns nil for whitespace-only header" do
    request = FakeRequest.new(headers: { "X-Tenant-Identifier" => "   " })
    assert_nil Lakeraven::EHR.configuration.tenant_resolver.call(request)
  end

  test "default facility_resolver reads X-Facility-Identifier header" do
    request = FakeRequest.new(headers: { "X-Facility-Identifier" => "fac_main" })
    assert_equal "fac_main", Lakeraven::EHR.configuration.facility_resolver.call(request)
  end

  test "host application can override tenant_resolver with subdomain extraction" do
    # This locks in the abstraction the production SaaS app relies on:
    # the engine doesn't care how the host app derives a tenant from
    # the request, only that the resolver returns a string or nil.
    Lakeraven::EHR.configure do |config|
      config.tenant_resolver = ->(request) {
        sub = request.host.split(".").first
        sub.start_with?("tnt-") ? sub.delete_prefix("tnt-") : nil
      }
    end
    request = FakeRequest.new(host: "tnt-acme.example.com")
    assert_equal "acme", Lakeraven::EHR.configuration.tenant_resolver.call(request)
  end

  test "subdomain resolver returns nil on a host with no tnt- prefix" do
    Lakeraven::EHR.configure do |config|
      config.tenant_resolver = ->(request) {
        sub = request.host.split(".").first
        sub.start_with?("tnt-") ? sub.delete_prefix("tnt-") : nil
      }
    end
    request = FakeRequest.new(host: "www.example.com")
    assert_nil Lakeraven::EHR.configuration.tenant_resolver.call(request)
  end
end
