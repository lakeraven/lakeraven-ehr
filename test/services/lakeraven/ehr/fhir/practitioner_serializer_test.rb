# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class PractitionerSerializerTest < ActiveSupport::TestCase
        test "serializes resourceType and id" do
          result = serialize(build_practitioner)

          assert_equal "Practitioner", result[:resourceType]
          refute_nil result[:id]
        end

        test "includes NPI identifier" do
          result = serialize(build_practitioner(npi: "1234567890"))

          npi = result[:identifier].find { |i| i[:system]&.include?("npi") }
          refute_nil npi
          assert_equal "1234567890", npi[:value]
        end

        test "includes name with family and given" do
          result = serialize(build_practitioner(name: "MARTINEZ,SARAH"))

          name = result[:name]&.first
          refute_nil name
          assert_equal "MARTINEZ", name[:family]
        end

        test "includes qualification with specialty" do
          result = serialize(build_practitioner(specialty: "Cardiology"))

          quals = result[:qualification]
          refute_nil quals
          assert quals.any? { |q| q[:code][:text] == "Cardiology" }
        end

        test "includes telecom with phone" do
          result = serialize(build_practitioner(phone: "907-555-9999"))

          telecom = result[:telecom]&.first
          refute_nil telecom
          assert_equal "phone", telecom[:system]
          assert_equal "907-555-9999", telecom[:value]
        end

        test "omits phone when blank" do
          result = serialize(build_practitioner(phone: nil))

          assert_empty(result[:telecom] || [])
        end

        test "handles missing optional fields" do
          pract = Practitioner.new(ien: 1, name: "DOE,JOHN")
          result = PractitionerSerializer.call(pract)

          assert_equal "Practitioner", result[:resourceType]
        end

        test "redaction policy applies" do
          result = serialize(build_practitioner)
          policy = RedactionPolicy.new(view: :research)
          redacted = policy.apply(result)

          assert_equal "Practitioner", redacted[:resourceType]
        end

        private

        def build_practitioner(attrs = {})
          defaults = {
            ien: 101, name: "MARTINEZ,SARAH", title: "MD",
            service_section: "Internal Medicine", specialty: "Cardiology",
            npi: "1234567890", phone: "907-555-9999"
          }
          Practitioner.new(defaults.merge(attrs))
        end

        def serialize(practitioner)
          PractitionerSerializer.call(practitioner)
        end
      end
    end
  end
end
