# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::Adapters::BaseTest < ActiveSupport::TestCase
  Base = Lakeraven::EHR::Adapters::Base

  test "search_patients raises NotImplementedError on the base class" do
    error = assert_raises(NotImplementedError) do
      Base.new.search_patients(tenant_identifier: "tnt_test")
    end
    assert_match(/search_patients/, error.message)
  end

  test "find_patient raises NotImplementedError on the base class" do
    error = assert_raises(NotImplementedError) do
      Base.new.find_patient(tenant_identifier: "tnt_test", patient_identifier: "pt_x")
    end
    assert_match(/find_patient/, error.message)
  end

  test "subclass that implements search_patients does not raise" do
    subclass = Class.new(Base) do
      def search_patients(**)
        []
      end
    end
    assert_equal [], subclass.new.search_patients(tenant_identifier: "tnt_test")
  end
end
