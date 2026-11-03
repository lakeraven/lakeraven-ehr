# frozen_string_literal: true

namespace :lakeraven_ehr do
  namespace :consent_templates do
    desc "Install the synthetic in-clinic consent templates"
    task install: :environment do
      Lakeraven::EHR::ConsentTemplate.install_defaults!
    end
  end
end
