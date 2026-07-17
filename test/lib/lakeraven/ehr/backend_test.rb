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

  def test_rpms_backend_resolves_rpms_practitioner_api
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    assert_equal RpmsRpc::Practitioner, Lakeraven::EHR::Backend.current.practitioner_api
  end

  def test_vista_backend_resolves_vista_practitioner_api
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal VistaRpc::Practitioner, Lakeraven::EHR::Backend.current.practitioner_api
  end

  def test_rpms_backend_resolves_rpms_vital_api
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    assert_equal RpmsRpc::Vital, Lakeraven::EHR::Backend.current.vital_api
  end

  def test_vista_backend_resolves_vista_vital_api
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal VistaRpc::Vital, Lakeraven::EHR::Backend.current.vital_api
  end

  def test_rpms_backend_resolves_rpms_lab_api
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    assert_equal RpmsRpc::Lab, Lakeraven::EHR::Backend.current.lab_api
  end

  def test_vista_backend_resolves_vista_lab_api
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal VistaRpc::Lab, Lakeraven::EHR::Backend.current.lab_api
  end

  def test_unknown_backend_falls_back_to_rpms
    Lakeraven::EHR.configure { |c| c.backend = :some_other_system }
    assert_equal RpmsRpc::Patient, Lakeraven::EHR::Backend.current.patient_api
    assert_equal RpmsRpc::Practitioner, Lakeraven::EHR::Backend.current.practitioner_api
    assert_equal RpmsRpc::Vital, Lakeraven::EHR::Backend.current.vital_api
    assert_equal RpmsRpc::Lab, Lakeraven::EHR::Backend.current.lab_api
  end

  def test_rpms_backend_resolves_rpms_problem_api
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    assert_equal RpmsRpc::Problem, Lakeraven::EHR::Backend.current.problem_api
  end

  def test_vista_backend_resolves_vista_problem_api
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal VistaRpc::Problem, Lakeraven::EHR::Backend.current.problem_api
  end

  def test_rpms_backend_resolves_rpms_allergy_api
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    assert_equal RpmsRpc::Allergy, Lakeraven::EHR::Backend.current.allergy_api
  end

  def test_vista_backend_resolves_vista_allergy_api
    Lakeraven::EHR.configure { |c| c.backend = :vista }
    assert_equal VistaRpc::Allergy, Lakeraven::EHR::Backend.current.allergy_api
  end

  def test_backend_reset_creates_new_adapter
    Lakeraven::EHR.configure { |c| c.backend = :rpms }
    first = Lakeraven::EHR::Backend.current
    Lakeraven::EHR::Backend.reset!
    second = Lakeraven::EHR::Backend.current
    refute_same first, second
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
