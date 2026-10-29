# frozen_string_literal: true

require "ostruct"

module DrugInteractionAdapterTestHelper
  UNAVAILABLE_INCOMPLETE_REASON =
    "Drug interaction checking is not available on this server."

  BUILDER_FAILURE_INCOMPLETE_REASON =
    "Drug interaction check could not be completed."

  CDS_UNAVAILABLE_INCOMPLETE_ALERT_MESSAGE =
    "Drug interactions could not be checked: drug interaction checking is not available on this server."

  CDS_GENERIC_INCOMPLETE_ALERT_MESSAGE =
    "Drug interactions could not be checked: the drug interaction check did not complete."

  CDS_DATA_FETCH_INCOMPLETE_ALERT_MESSAGE =
    "Drug interactions could not be checked: the patient's medications or allergies could not be retrieved."

  def drug_interaction_med(display, code)
    ::OpenStruct.new(medication_display: display, medication_code: code)
  end

  def drug_interaction_allergy(allergen, code, category = "medication")
    ::OpenStruct.new(allergen: allergen, allergen_code: code, category: category)
  end

  def with_drug_interaction_backend_env(env_backend: nil)
    original = ENV["DRUG_INTERACTION_BACKEND"]
    ENV["DRUG_INTERACTION_BACKEND"] = env_backend
    yield
  ensure
    ENV["DRUG_INTERACTION_BACKEND"] = original
  end

  def flunk_missing_drug_interaction_constant(name)
    flunk "missing Lakeraven::EHR::DrugInteraction::#{name}"
  end

  def drug_interaction_adapter_class(class_name)
    ::Lakeraven::EHR::DrugInteraction.const_get(class_name, false)
  rescue NameError
    flunk_missing_drug_interaction_constant(class_name)
  end

  def drug_interaction_adapter_not_available
    ::Lakeraven::EHR::DrugInteraction.const_get(:AdapterNotAvailable)
  rescue NameError
    flunk_missing_drug_interaction_constant("AdapterNotAvailable")
  end

  def build_drug_interaction_service(**options)
    ::Lakeraven::EHR::DrugInteractionService.new(**options)
  rescue ArgumentError => e
    flunk "DrugInteractionService must accept adapter factory options: #{e.message}"
  end

  def reset_drug_interaction_adapter_registrations!
    ::Lakeraven::EHR::DrugInteraction.const_get(:AdapterFactory).reset_registrations!
  rescue NameError
    nil
  end

  def drug_interaction_adapter_factory
    ::Lakeraven::EHR::DrugInteraction.const_get(:AdapterFactory)
  rescue NameError
    flunk_missing_drug_interaction_constant("AdapterFactory")
  end

  def with_drug_interaction_factory(&block)
    original_env = ENV["DRUG_INTERACTION_BACKEND"]
    original_rails_env = Rails.env
    reset_drug_interaction_adapter_registrations!
    yield
  ensure
    ENV["DRUG_INTERACTION_BACKEND"] = original_env
    Rails.env = original_rails_env
    reset_drug_interaction_adapter_registrations!
  end

  def assert_same_yaml_interaction_alerts(expected_adapter, actual_adapter, medications:, allergies:, proposed:)
    expected = expected_adapter.check_interactions(medications + [ proposed ]) +
               expected_adapter.check_allergies(proposed, allergies)
    actual = actual_adapter.check_interactions(medications + [ proposed ]) +
             actual_adapter.check_allergies(proposed, allergies)

    assert_equal expected.length, actual.length
    expected.zip(actual).each do |exp, act|
      assert_equal exp.severity, act.severity
      assert_equal exp.drug_a, act.drug_a
      assert_equal exp.drug_b, act.drug_b
      assert_equal exp.description, act.description
      assert_equal exp.interaction_type, act.interaction_type
    end
  end
end
