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
end
