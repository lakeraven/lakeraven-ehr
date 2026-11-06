# frozen_string_literal: true

DRUG_INTERACTION_ISOLATED_FEATURES = %w[
  drug_interactions.feature
  clinical_decision_support.feature
].freeze

Before do |scenario|
  next unless DRUG_INTERACTION_ISOLATED_FEATURES.include?(File.basename(scenario.location.file))

  @__saved_drug_interaction_backend = ENV["DRUG_INTERACTION_BACKEND"]
  @__saved_drug_interaction_rails_env = Rails.env
  ENV.delete("DRUG_INTERACTION_BACKEND")
  Lakeraven::EHR::DrugInteraction::AdapterFactory.reset_registrations!
end

After do |scenario|
  next unless DRUG_INTERACTION_ISOLATED_FEATURES.include?(File.basename(scenario.location.file))

  ENV["DRUG_INTERACTION_BACKEND"] = @__saved_drug_interaction_backend
  Rails.env = @__saved_drug_interaction_rails_env if defined?(@__saved_drug_interaction_rails_env)
  Lakeraven::EHR::DrugInteraction::AdapterFactory.reset_registrations!
end
