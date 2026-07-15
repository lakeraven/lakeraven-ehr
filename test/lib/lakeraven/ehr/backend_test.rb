# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::BackendTest < ActiveSupport::TestCase
  def setup
    @original_backend = Lakeraven::EHR.configuration.backend
  end

  def teardown
    Lakeraven::EHR.reset_configuration!
  end

  def test_default_backend_is_rpms
    assert_equal :rpms, Lakeraven::EHR.configuration.backend
  end

  def test_rpms_backend_resolves_rpms_patient_api
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    assert_equal RpmsRpc::Patient, Lakeraven::EHR::Backend.current.patient_api
  end

  def test_vista_backend_resolves_vista_patient_api
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal VistaRpc::Patient, Lakeraven::EHR::Backend.current.patient_api
  end

  def test_configure_applies_client_to_vista_rpc
    original_client = VistaRpc.configuration.client
    mock_client = Object.new
    Lakeraven::EHR.configure { |c| c.client = mock_client }
    assert_equal mock_client, VistaRpc.client
  ensure
    VistaRpc.configure { |c| c.client = original_client }
  end

  def test_reset_configuration_resets_backend
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    Lakeraven::EHR.reset_configuration!
    assert_equal :rpms, Lakeraven::EHR.configuration.backend
  end
end
