# frozen_string_literal: true

# Process-global Lakeraven::EHR.configuration — always restore after each example.
module SupplementalProviderConfigHelper
  def with_supplemental_providers(observations: :__unset__, allergy_intolerances: :__unset__)
    config = Lakeraven::EHR.configuration
    saved_observations = config.supplemental_observations_provider
    saved_allergies = config.supplemental_allergy_intolerances_provider

    config.supplemental_observations_provider = observations unless observations == :__unset__
    config.supplemental_allergy_intolerances_provider = allergy_intolerances unless allergy_intolerances == :__unset__
    yield
  ensure
    config.supplemental_observations_provider = saved_observations
    config.supplemental_allergy_intolerances_provider = saved_allergies
  end
end
