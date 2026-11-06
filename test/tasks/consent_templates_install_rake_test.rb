# frozen_string_literal: true

require "test_helper"
require "rake"

class ConsentTemplatesInstallRakeTest < ActiveSupport::TestCase
  KEYS = %w[bh-treatment telehealth release-of-information].freeze

  setup do
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    Rails.application.load_tasks
  end

  test "lakeraven_ehr:consent_templates:install creates three templates and a second invoke adds nothing" do
    task = Rake::Task["lakeraven_ehr:consent_templates:install"]

    assert_difference -> { Lakeraven::EHR::ConsentTemplate.count }, +3 do
      task.invoke
    end
    KEYS.each do |key|
      assert Lakeraven::EHR::ConsentTemplate.exists?(key: key, version: 1), "expected #{key} v1"
    end

    task.reenable
    assert_no_difference -> { Lakeraven::EHR::ConsentTemplate.count } do
      task.invoke
    end
  end
end
