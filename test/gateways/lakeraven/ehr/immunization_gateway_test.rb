# frozen_string_literal: true

require "test_helper"

# Tests for ImmunizationGateway — wraps RpmsRpc::Immunization.
# Replaces the previous Allergy-stub delegation (wrong domain) now that
# rpms-rpc ships a structured Immunization read (lakeraven/rpms-rpc#107).
module Lakeraven
  module EHR
    class ImmunizationGatewayTest < ActiveSupport::TestCase
      class FakeImmunizationAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def for_patient(dfn)
          @calls << { method: :for_patient, args: [ dfn ] }
          @returns[:for_patient] || []
        end

        def find(ien)
          @calls << { method: :find, args: [ ien ] }
          @returns[:find]
        end
      end

      STRUCTURED_RECORD = {
        ien: 7001,
        vaccine_code: "207",
        vaccine_display: "COVID-19 Pfizer-BioNTech, mRNA",
        status: "completed",
        lot_number: "EX1234",
        expiration_date: Date.new(2026, 12, 31),
        site: "Left deltoid",
        route: "IM",
        performer_duz: "301",
        performer_name: "MARTINEZ,SARAH",
        occurrence_datetime: Time.utc(2026, 1, 15, 10, 0, 0),
        dose_quantity: 0.3,
        dose_unit: "mL",
        manufacturer: "Pfizer-BioNTech",
        vfc_eligibility_code: "V04",
        funding_source: "VFC"
      }.freeze

      # --- via: nil ---

      test "for_patient returns empty when no provider is available" do
        assert_equal [], ImmunizationGateway.for_patient(1, via: nil)
      end

      test "find returns nil when no provider is available" do
        assert_nil ImmunizationGateway.find(7001, via: nil)
      end

      # --- delegation + coercion ---

      test "for_patient delegates with dfn coerced to a string and returns structured records" do
        fake = FakeImmunizationAPI.new(returns: { for_patient: [ STRUCTURED_RECORD ] })

        result = ImmunizationGateway.for_patient(1, via: fake)

        assert_equal 1, result.length
        assert_equal "207", result.first[:vaccine_code]
        assert_equal "EX1234", result.first[:lot_number]
        assert_equal "V04", result.first[:vfc_eligibility_code]
        assert_equal [ "1" ], fake.calls.first[:args]
      end

      test "find delegates with ien coerced to a string and returns a single record" do
        fake = FakeImmunizationAPI.new(returns: { find: STRUCTURED_RECORD })

        result = ImmunizationGateway.find(7001, via: fake)

        assert_equal "207", result[:vaccine_code]
        assert_equal "Pfizer-BioNTech", result[:manufacturer]
        assert_equal [ "7001" ], fake.calls.first[:args]
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::Immunization now that the gem ships it" do
        provider = ImmunizationGateway.default_provider
        refute_nil provider, "expected RpmsRpc::Immunization to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::Immunization", provider.name
      end
    end
  end
end
