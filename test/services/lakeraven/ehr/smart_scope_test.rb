# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SmartScopeTest < ActiveSupport::TestCase
      PERMISSIONS = %w[c r u d s].freeze

      # v1 suffix => the v2 permissions it stands for.
      TRANSLATION = { "read" => "rs", "write" => "cud", "*" => "cruds" }.freeze

      test "a v1 scope and its v2 spelling permit exactly the same thing" do
        %w[patient user system].product(%w[Patient *], TRANSLATION.to_a).each do |context, type, (v1, v2)|
          v1_scope = "#{context}/#{type}.#{v1}"
          v2_scope = "#{context}/#{type}.#{v2}"

          %w[Patient Observation].product(PERMISSIONS).each do |resource_type, permission|
            assert_equal SmartScope.permits?(v2_scope, resource_type, permission),
              SmartScope.permits?(v1_scope, resource_type, permission),
              "#{v1_scope} vs #{v2_scope} on #{resource_type}.#{permission}"
          end
          assert_equal v2_scope, SmartScope.normalize(v1_scope)
        end
      end

      test "each v2 permission grants only itself" do
        PERMISSIONS.each do |granted|
          PERMISSIONS.each do |asked|
            assert_equal granted == asked, SmartScope.permits?("system/Patient.#{granted}", "Patient", asked),
              "system/Patient.#{granted} asked for #{asked}"
          end
        end
      end

      test "a type scope does not reach another type; a wildcard reaches every type" do
        refute SmartScope.permits?("system/Patient.rs", "Observation", "r")
        assert SmartScope.permits?("system/*.rs", "Observation", "r")
      end

      test "a scope it cannot read grants nothing" do
        [
          "patient/Observation.rs?category=laboratory", # granular: the query cannot be applied
          "system/Patient.sr",                          # permissions out of order
          "system/Patient.rx",
          "system/Patient.",
          "admin/Patient.rs",
          "openid", "launch", "fhirUser"
        ].each do |scope|
          PERMISSIONS.each { |permission| refute SmartScope.permits?(scope, "Patient", permission), scope }
        end
      end

      test "a context filter excludes the other contexts" do
        refute SmartScope.permits?("user/Measure.c", "Measure", "c", contexts: %w[system])
        assert SmartScope.permits?("system/Measure.write", "Measure", "c", contexts: %w[system])
      end

      test "narrowing keeps the requested type and the permissions both sides name" do
        requested = SmartScope.parse("system/Patient.cruds")

        assert_equal "system/Patient.rs", requested.narrowed_by(SmartScope.parse("system/*.read")).to_s
        assert_nil requested.narrowed_by(SmartScope.parse("system/Observation.read"))
        assert_nil SmartScope.parse("system/*.rs").narrowed_by(SmartScope.parse("system/Patient.rs"))
        assert_nil requested.narrowed_by(SmartScope.parse("user/Patient.rs"))
      end
    end
  end
end
