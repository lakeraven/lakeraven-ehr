# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PractitionerGatewayVistaBackendTest < ActiveSupport::TestCase
      def setup
        @original_backend = Lakeraven::EHR.configuration.backend
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!
      end

      def teardown
        Lakeraven::EHR.configure { |c| c.backend = @original_backend }
        Lakeraven::EHR::Backend.reset!
      end

      test "find returns practitioner through VistA backend" do
        practitioner = PractitionerGateway.find(101)

        assert_not_nil practitioner
        assert_instance_of Practitioner, practitioner
        assert_equal 101, practitioner.ien
        assert_equal "MARTINEZ,SARAH", practitioner.name
      end

      test "find returns nil for mismatched IEN" do
        practitioner = PractitionerGateway.find(999)

        assert_nil practitioner
      end

      test "search returns practitioners through VistA backend" do
        practitioners = PractitionerGateway.search("MARTINEZ")

        assert practitioners.is_a?(Array)
        assert practitioners.length >= 1
        practitioners.each { |p| assert_instance_of Practitioner, p }
      end

      test "VistA practitioner serializes to FHIR" do
        practitioner = PractitionerGateway.find(101)
        fhir = practitioner.to_fhir

        assert_equal "Practitioner", fhir[:resourceType]
        assert_equal "101", fhir[:id]
        assert_equal "MARTINEZ", fhir[:name].first[:family]
      end
    end
  end
end
