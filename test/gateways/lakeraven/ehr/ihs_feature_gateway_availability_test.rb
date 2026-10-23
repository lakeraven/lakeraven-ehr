# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Fail closed at the gateway (#647): no backend call, FeatureUnavailable names the capability.
    #
    # bprm_scheduling is BSDX/BPRM scheduling writes and BSDX report RPCs only.
    # Stock ORWPT APPTLST reads (patient_appointments, cancelled_appointments,
    # routing_slip, and EncounterGateway.for_patient on the chart) stay available.
    class IhsFeatureGatewayAvailabilityTest < ActiveSupport::TestCase
      include BrokerStubbing
      include IhsFeatureAvailabilityTestHelper

      APPT_ROW = "3260820.0900^15^CLINIC^scheduled"
      APPT_FUTURE_ROW = "3260901.0900^20^FUTURE CLINIC^scheduled"
      APPT_CANCELLED_ROW = "3251201.0900^15^CLINIC^cancelled"

      # Public SchedulingGateway entry points that reach BSDX or RpmsRpc::Scheduling.
      BSDX_SCHEDULING_GATEWAY_CALLS = {
        book: -> { SchedulingGateway.book(15, 42, at: "2026-08-20 09:00", minutes: 20) },
        cancel: -> { SchedulingGateway.cancel(7001, cancel_type: "clinic", reason: "1") },
        no_show: -> { SchedulingGateway.no_show(7001) },
        check_in: -> { SchedulingGateway.check_in(7001) },
        check_in_undo: -> { SchedulingGateway.check_in(7001, undo: true) },
        rebook: lambda {
          SchedulingGateway.rebook(7001, clinic_ien: 15, at: "2026-08-21 10:00",
                                 reason: "Patient request", dfn: 42, original_at: "2026-08-20 09:00")
        },
        availability: -> { SchedulingGateway.availability(15, Date.new(2026, 8, 20)) },
        access_blocks: -> { SchedulingGateway.access_blocks(15) },
        clinic_schedule: -> { SchedulingGateway.clinic_schedule(15, Date.new(2026, 8, 20)) },
        waiting_list: -> { SchedulingGateway.waiting_list(15) },
        waiting_list_add: -> { SchedulingGateway.waiting_list_add(15, 42, reason: "routine") },
        set_availability_config: lambda {
          SchedulingGateway.set_availability_config(15, days: %w[mon], start_time: "08:00",
                                                              end_time: "17:00", minutes: 20)
        },
        add_holiday: -> { SchedulingGateway.add_holiday(15, Date.new(2026, 12, 25), label: "Christmas") },
        remove_holiday: -> { SchedulingGateway.remove_holiday(15, Date.new(2026, 12, 25)) }
      }.freeze

      STOCK_ORWPT_SCHEDULING_READS = {
        patient_appointments: -> { SchedulingGateway.patient_appointments(42) },
        cancelled_appointments: -> { SchedulingGateway.cancelled_appointments(42) },
        routing_slip: -> { SchedulingGateway.routing_slip(42, Date.new(2026, 8, 20)) }
      }.freeze

      teardown { teardown_restricted_backend }

      BSDX_SCHEDULING_GATEWAY_CALLS.each do |entry, invoke|
        test "bprm_scheduling: SchedulingGateway.#{entry} raises without a broker call" do
          fake = scheduling_fake_broker
          with_restricted_backend(client: fake) do
            assert_feature_unavailable(:bprm_scheduling) { invoke.call }
          end
          assert_empty fake.calls
        end
      end

      STOCK_ORWPT_SCHEDULING_READS.each do |entry, invoke|
        test "bprm_scheduling: SchedulingGateway.#{entry} still uses #{SchedulingGateway::APPTLST_RPC} without bprm_scheduling" do
          fake = FakeBroker.new.on(SchedulingGateway::APPTLST_RPC, [ APPT_ROW, APPT_FUTURE_ROW, APPT_CANCELLED_ROW ])
          with_restricted_backend(client: fake) do
            result = invoke.call
            assert result[:success], result.inspect
            assert_equal 1, fake.calls_for(SchedulingGateway::APPTLST_RPC).size
          end
        end
      end

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
        delete: -> { ServiceRequestGateway.delete("SR-DRAFT-001") },
        cancel: -> { ServiceRequestGateway.cancel("SR-AUTHORIZED-001", reason: "Patient withdrew") },
        deletable?: -> { ServiceRequestGateway.deletable?("SR-DRAFT-001") }
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
            ImmunizationRefusalGateway.record(1, "207", reason_code: "PATOBJ", via: fake)
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

      private

      def scheduling_fake_broker
        FakeBroker.new
                  .on("BSDX ADD NEW APPOINTMENT", "7001^")
                  .on("BSDX CANCEL APPOINTMENT", [ "" ])
                  .on("BSDX NOSHOW", "1^")
                  .on("BSDX CHECKIN APPOINTMENT", "0")
                  .on(SchedulingGateway::AVAILABILITY_RPC, "")
                  .on(SchedulingGateway::ACCESS_BLOCK_RPC, "")
                  .on(SchedulingGateway::SCHEDULE_RPC, "")
                  .on(SchedulingGateway::WAITLIST_RPC, "")
                  .on(SchedulingGateway::WAITLIST_ADD_RPC, "1^9001")
                  .on(SchedulingGateway::CONFIG_RPC, "1^")
                  .on(SchedulingGateway::ADD_HOLIDAY_RPC, "1^")
                  .on(SchedulingGateway::DEL_HOLIDAY_RPC, "1^")
                  .on(SchedulingGateway::UNCHECKIN_RPC, "1^")
      end

    end
  end
end
