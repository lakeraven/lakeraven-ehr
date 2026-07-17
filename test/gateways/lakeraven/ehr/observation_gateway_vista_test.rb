# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ObservationGatewayVistaBackendTest < ActiveSupport::TestCase
      def setup
        @original_backend = Lakeraven::EHR.configuration.backend
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!
      end

      def teardown
        Lakeraven::EHR.configure { |c| c.backend = @original_backend }
        Lakeraven::EHR::Backend.reset!
      end

      test "for_patient returns vitals through VistA backend" do
        vitals = ObservationGateway.for_patient(1)

        assert_kind_of Array, vitals
        assert vitals.any? { |v| v[:type] == "BP" && v[:value] == "120/80" }
      end

      test "labs_for_patient returns lab results through VistA backend" do
        labs = ObservationGateway.labs_for_patient(1)

        assert_kind_of Array, labs
        assert labs.any? { |r| r[:ien] == 9001 && r[:test_name] == "718-7" }
        assert labs.all? { |r| r.key?(:abnormal) }
      end

      test "labs_for_patient returns empty for unknown patient" do
        assert_equal [], ObservationGateway.labs_for_patient(999_999)
      end
    end
  end
end
