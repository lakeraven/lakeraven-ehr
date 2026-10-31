# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Fail closed at the gateway (#647): no backend call, FeatureUnavailable names the capability.
    #
    # bprm_scheduling gates the BSDX scheduling screens (see
    # SchedulingBookAppointmentTest); the chart's stock ORWPT APPTLST rows
    # (EncounterGateway.for_patient) stay available.
    class IhsFeatureGatewayAvailabilityTest < ActiveSupport::TestCase
      include BrokerStubbing
      include IhsFeatureAvailabilityTestHelper

      teardown { teardown_restricted_backend }

      test "bprm_scheduling does not gate EncounterGateway.for_patient (stock ORWPT APPTLST chart rows)" do
        RpmsRpc.client.seed_keyed_collection(:patient_appointments, "1", [
          { datetime: Date.new(2026, 5, 1), location_ien: 20, location: "Scheduling Clinic Future", status: "SCHEDULED" }
        ])
        with_restricted_backend do
          visits = EncounterGateway.for_patient(1)
          assert visits.any? { |v| v[:location] == "Scheduling Clinic Future" }
        end
      ensure
        RpmsRpc.client.seed_keyed_collection(:patient_appointments, "1", [])
      end

      PRC_REFERRAL_GATEWAY_CALLS = {
        for_patient: -> { ServiceRequestGateway.for_patient(1) },
        create: lambda {
          ServiceRequestGateway.create(1, {
            provider_ien: 99999,
            specialty: "Cardiology",
            reason: "Chest pain workup",
            priority: "ROUTINE",
            requested_date: Date.new(2026, 6, 1)
          })
        },
        cancel: -> { ServiceRequestGateway.cancel("SR-AUTHORIZED-001") }
      }.freeze

      PRC_REFERRAL_GATEWAY_CALLS.each do |entry, invoke|
        test "prc_referrals: ServiceRequestGateway.#{entry} raises without an RPC call" do
          before = RpmsRpc.client.received_calls.length
          with_restricted_backend do
            assert_feature_unavailable(:prc_referrals) { invoke.call }
          end
          assert_no_rpc_calls_since(before)
        end
      end

      TRIBAL_ENROLLMENT_GATEWAY_CALLS = {
        enrollment_details: -> { TribalEnrollmentGateway.enrollment_details(1) },
        validate: -> { TribalEnrollmentGateway.validate("EXNH-12345") },
        eligibility: -> { TribalEnrollmentGateway.eligibility(1) },
        service_unit: -> { TribalEnrollmentGateway.service_unit(1) },
        tribe_info: -> { TribalEnrollmentGateway.tribe_info(1) }
      }.freeze

      TRIBAL_ENROLLMENT_GATEWAY_CALLS.each do |entry, invoke|
        test "tribal_enrollment: TribalEnrollmentGateway.#{entry} raises without an RPC call" do
          before = RpmsRpc.client.received_calls.length
          with_restricted_backend do
            assert_feature_unavailable(:tribal_enrollment) { invoke.call }
          end
          assert_no_rpc_calls_since(before)
        end
      end

      test "tribal_enrollment: host may replace TribalEnrollmentGateway.enrollment_details on a restricted backend" do
        gw = TribalEnrollmentGateway
        original = gw.method(:enrollment_details)
        with_restricted_backend do
          gw.define_singleton_method(:enrollment_details) { |_dfn| { replaced: true } }
          assert_equal({ replaced: true }, gw.enrollment_details(1))
        end
      ensure
        gw.define_singleton_method(:enrollment_details, original)
      end

      test "bprm_registration: RegistrationGateway.register raises without a broker call" do
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^99^")
        with_restricted_backend(client: fake) do
          assert_feature_unavailable(:bprm_registration) { RegistrationGateway.register(name: "SYNTH,TEST") }
        end
        assert_empty fake.calls
      end

      test "bprm_registration does not gate PatientGateway.find (stock ORWPT patient read)" do
        with_restricted_backend do
          patient = PatientGateway.find(1)
          assert_equal 1, patient.dfn
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "ihs_immunization: ImmunizationGateway.for_patient raises without a provider call" do
        called = false
        fake = Object.new
        fake.define_singleton_method(:for_patient) { |*| called = true; [] }
        with_restricted_backend do
          assert_feature_unavailable(:ihs_immunization) { ImmunizationGateway.for_patient(1, via: fake) }
        end
        refute called
      end

      test "ihs_immunization: ImmunizationRefusalGateway.record raises without a provider call" do
        called = false
        fake = Object.new
        fake.define_singleton_method(:record) { |*| called = true; { success: true } }
        with_restricted_backend do
          assert_feature_unavailable(:ihs_immunization) do
            ImmunizationRefusalGateway.record(1, "207", reason_ien: "4", via: fake)
          end
        end
        refute called
      end

      GUARD_BYPASS_CASES = {
        "ImmunizationGateway.for_patient via method().call" => {
          capability: :ihs_immunization,
          invoke: -> { ImmunizationGateway.method(:for_patient).call(1) },
          track_rpc: true
        },
        "ImmunizationGateway.for_patient via instance_method#bind_call" => {
          capability: :ihs_immunization,
          invoke: lambda {
            ImmunizationGateway.singleton_class
                               .instance_method(:for_patient)
                               .bind_call(ImmunizationGateway, 1)
          },
          track_rpc: true
        },
        "RegistrationGateway.register via method().call" => {
          capability: :bprm_registration,
          invoke: -> { RegistrationGateway.method(:register).call(name: "SYNTH,TEST") },
          track_rpc: false
        },
        "RegistrationGateway.register via instance_method#bind_call" => {
          capability: :bprm_registration,
          invoke: lambda {
            RegistrationGateway.singleton_class
                                .instance_method(:register)
                                .bind_call(RegistrationGateway, name: "SYNTH,TEST")
          },
          track_rpc: false
        }
      }.freeze

      GUARD_BYPASS_CASES.each do |label, config|
        test "guard bypass: #{label} raises FeatureUnavailable with no backend call" do
          before_rpc = RpmsRpc.client.received_calls.length
          fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^99^")
          with_restricted_backend(client: fake) do
            assert_feature_unavailable(config.fetch(:capability)) { config.fetch(:invoke).call }
          end
          assert_empty fake.calls
          assert_no_rpc_calls_since(before_rpc) if config.fetch(:track_rpc)
        end
      end

      %i[for_patient register].each do |method_name|
        gateway = method_name == :for_patient ? ImmunizationGateway : RegistrationGateway
        capability = method_name == :for_patient ? :ihs_immunization : :bprm_registration

        test "guard bypass: restored #{gateway.name}.#{method_name} works on rpms and stays guarded when restricted" do
          stub_name = :"__ihs_feature_stub_#{method_name}"
          eigen = gateway.singleton_class
          eigen.alias_method stub_name, method_name
          eigen.define_method(method_name) { |*_args, **_kwargs| :stubbed }
          eigen.remove_method(method_name)
          eigen.alias_method method_name, stub_name
          eigen.remove_method(stub_name)

          assert_equal :rpms, Lakeraven::EHR.configuration.backend
          if method_name == :for_patient
            assert_kind_of Array, gateway.for_patient(1)
          else
            fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^12345^")
            use_broker(fake) { assert gateway.register(name: "SYNTH,TEST")[:success] }
          end

          with_restricted_backend do
            assert_feature_unavailable(capability) do
              if method_name == :register
                gateway.register(name: "SYNTH,TEST")
              else
                gateway.for_patient(1)
              end
            end
          end
        end
      end

      test "pcc_screens: ProcedureGateway.add raises without an RPC call" do
        before = RpmsRpc.client.received_calls.length
        with_restricted_backend do
          assert_feature_unavailable(:pcc_screens) { ProcedureGateway.add(1, 2090061, "99213") }
        end
        assert_no_rpc_calls_since(before)
      end

      test "pcc_screens: ProcedureGateway.add still delegates on rpms" do
        assert_equal :rpms, Lakeraven::EHR.configuration.backend
        RpmsRpc.client.seed_scalar(:procedure_save, "1", "42")
        result = ProcedureGateway.add(1, 2090061, "99213")
        assert result[:success]
        assert_equal 42, result[:ien]
      end

      # PCC V-file writes (BGO *SET via rpms-rpc) — gated under :pcc_screens (#647).
      PCC_SCREEN_WRITES = {
        "ExamComponentGateway.add" => {
          provider_method: :add,
          invoke: lambda { |fake|
            ExamComponentGateway.add(1, 2090061, "SKIN", finding: "Normal", via: fake)
          }
        },
        "HealthFactorGateway.add" => {
          provider_method: :add,
          invoke: lambda { |fake|
            HealthFactorGateway.add(1, 2090061, "TOB-CURRENT", level: "MODERATE", via: fake)
          }
        },
        "MeasurementGateway.add" => {
          provider_method: :add,
          invoke: lambda { |fake|
            MeasurementGateway.add(1, 2090061, "WT", 75, units: "kg", via: fake)
          }
        },
        "PovGateway.add" => {
          provider_method: :add,
          invoke: lambda { |fake|
            PovGateway.add(1, 2090061, "J45.909", narrative: "Asthma", via: fake)
          }
        }
      }.freeze

      PCC_SCREEN_WRITES.each do |label, config|
        test "pcc_screens: #{label} raises without a provider call" do
          called = false
          fake = Object.new
          fake.define_singleton_method(config.fetch(:provider_method)) { |*| called = true; { success: true } }
          with_restricted_backend do
            assert_feature_unavailable(:pcc_screens) { config.fetch(:invoke).call(fake) }
          end
          refute called
        end

        test "pcc_screens: #{label} still delegates on rpms" do
          assert_equal :rpms, Lakeraven::EHR.configuration.backend
          calls = []
          fake = Object.new
          fake.define_singleton_method(config.fetch(:provider_method)) do |*args, **kwargs|
            calls << { args: args, kwargs: kwargs }
            { success: true, ien: 1, raw: "1" }
          end
          result = config.fetch(:invoke).call(fake)
          assert_equal 1, calls.size
          assert result[:success]
        end
      end

      test "tribal_enrollment: Patient tribal_enrollment_details raises without an RPC call" do
        patient = Patient.new(dfn: 1, name: "Anderson,Alice", tribal_enrollment_number: "EXNH-12345")
        before = RpmsRpc.client.received_calls.length
        with_restricted_backend do
          assert_feature_unavailable(:tribal_enrollment) { patient.tribal_enrollment_details }
        end
        assert_no_rpc_calls_since(before)
      end

      IHS_IMMUNIZATION_ELIGIBILITY_CALLS = {
        patient_eligibility: -> { EligibilityGateway.patient_eligibility("1") },
        list_codes: -> { EligibilityGateway.list_codes }
      }.freeze

      IHS_IMMUNIZATION_ELIGIBILITY_CALLS.each do |entry, invoke|
        test "ihs_immunization: EligibilityGateway.#{entry} raises without an RPC call" do
          before = RpmsRpc.client.received_calls.length
          with_restricted_backend do
            assert_feature_unavailable(:ihs_immunization) { invoke.call }
          end
          assert_no_rpc_calls_since(before)
        end
      end

      test "ihs_immunization: EligibilityGateway still delegates on rpms" do
        assert_equal :rpms, Lakeraven::EHR.configuration.backend
        result = EligibilityGateway.patient_eligibility("1")
        assert_equal "V04", result[:code]
        assert EligibilityGateway.list_codes.any?
      end
    end
  end
end
