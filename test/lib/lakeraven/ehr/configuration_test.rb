# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::ConfigurationTest < ActiveSupport::TestCase
  def setup
    @original_client = VistaRpc.configuration.client
  end

  def teardown
    Lakeraven::EHR.reset_configuration!
    VistaRpc.configure { |c| c.client = @original_client }
  end

  def test_default_backend_is_rpms
    assert_equal :rpms, Lakeraven::EHR.configuration.backend
  end

  def test_default_client_is_nil
    assert_nil Lakeraven::EHR.configuration.client
  end

  def test_default_validate_fhir_us_core_is_false
    assert_equal false, Lakeraven::EHR.configuration.validate_fhir_us_core
  end

  def test_configure_sets_backend
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal :vista, Lakeraven::EHR.configuration.backend
  end

  def test_configure_sets_client
    mock_client = Object.new
    Lakeraven::EHR.configure { |c| c.client = mock_client }
    assert_equal mock_client, Lakeraven::EHR.configuration.client
    assert_equal mock_client, VistaRpc.client
  end

  def test_configure_sets_validate_fhir_us_core
    Lakeraven::EHR.configure { |c| c.validate_fhir_us_core = true }
    assert_equal true, Lakeraven::EHR.configuration.validate_fhir_us_core
  end

  def test_configure_resets_backend_cache
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    first = Lakeraven::EHR::Backend.current

    Lakeraven::EHR.configure { |c| c.backend = :vista }
    second = Lakeraven::EHR::Backend.current

    refute_same first, second
    assert_equal VistaRpc::Patient, second.patient_api
  end

  def test_reset_configuration_resets_all_defaults
    Lakeraven::EHR.configure do |c|
      c.backend = :vista
      c.client = Object.new
      c.validate_fhir_us_core = true
    end

    Lakeraven::EHR.reset_configuration!

    assert_equal :rpms,  Lakeraven::EHR.configuration.backend
    assert_nil Lakeraven::EHR.configuration.client
    assert_equal false, Lakeraven::EHR.configuration.validate_fhir_us_core
  end

  def test_reset_configuration_resets_backend_cache
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    first = Lakeraven::EHR::Backend.current

    Lakeraven::EHR.reset_configuration!
    second = Lakeraven::EHR::Backend.current

    refute_same first, second
    assert_equal :rpms, Lakeraven::EHR.configuration.backend
  end

  def test_no_phi_in_example_configuration
    config = Lakeraven::EHR::Configuration.new
    # Defaults must not contain real-looking patient/facility data or secrets.
    assert_nil config.tenant_resolver.call(stub_request_with(""))
    assert_nil config.facility_resolver.call(stub_request_with(""))
  end

  private

  def stub_request_with(tenant)
    Struct.new(:headers).new({ "X-Tenant-Identifier" => tenant })
  end
end
