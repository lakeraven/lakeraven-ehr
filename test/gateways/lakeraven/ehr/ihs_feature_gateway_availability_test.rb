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

      test "prc_referrals: ServiceRequestGateway.for_patient raises without calling Referral" do
        called = false
        with_restricted_backend do
          with_gateway_method(ServiceRequestGateway, :for_patient, ->(*) { called = true; [] }) do
            assert_feature_unavailable(:prc_referrals) { ServiceRequestGateway.for_patient(1) }
          end
        end
        refute called
      end

      test "tribal_enrollment: TribalEnrollmentGateway.enrollment_details raises without a backend call" do
        called = false
        with_restricted_backend do
          with_gateway_method(TribalEnrollmentGateway, :enrollment_details, ->(*) { called = true; {} }) do
            assert_feature_unavailable(:tribal_enrollment) { TribalEnrollmentGateway.enrollment_details(1) }
          end
        end
        refute called
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

      test "tribal_enrollment: Patient tribal_enrollment_details raises without calling the gateway" do
        patient = Patient.new(dfn: 1, name: "Anderson,Alice", tribal_enrollment_number: "EXNH-12345")
        called = false
        with_restricted_backend do
          with_gateway_method(TribalEnrollmentGateway, :enrollment_details, ->(*) { called = true; {} }) do
            assert_feature_unavailable(:tribal_enrollment) { patient.tribal_enrollment_details }
          end
        end
        refute called
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

      def with_gateway_method(gateway, name, impl)
        singleton = gateway.singleton_class
        original = singleton.instance_method(name)
        gateway.define_singleton_method(name, impl)
        yield
      ensure
        gateway.define_singleton_method(name, original)
      end
    end
  end
end
