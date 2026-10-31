# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Pins which broker RPCs back each IHS capability (#647). Gated methods must
    # use IHS-only namespaces (BMC, AG/BPRM registration, BGOVIMM/BGOREF, BSDX,
    # and the #9000001 tribal projection). Stock VistA RPCs on the same gateway
    # must not be gated — see scheduling ORWPT APPTLST reads.
    class IhsFeatureRpcScopeTest < ActiveSupport::TestCase
      GATED_METHOD_IHS_RPC = {
        prc_referrals: {
          "ServiceRequestGateway.for_patient" => "BMC SEARCH REFERRAL",
          "ServiceRequestGateway.create" => "BMC ADD REFERRAL"
        },
        tribal_enrollment: {
          "TribalEnrollmentGateway.enrollment_details" => "DDR GETS ENTRY DATA",
          "TribalEnrollmentGateway.validate" => "DDR VALIDATOR",
          "TribalEnrollmentGateway.eligibility" => "DDR GETS ENTRY DATA"
        },
        bprm_registration: {
          "RegistrationGateway.register" => "AGG ADD NEW PATIENT",
          "RegistrationGateway.update" => "AGG UPDATE PATIENT"
        },
        bprm_scheduling: {
          "AppointmentBookingGateway.book" => "BSDX ADD NEW APPOINTMENT",
          "AppointmentCancellationGateway.cancel" => "BSDX CANCEL APPOINTMENT",
          "AppointmentCheckinGateway.check_in" => "BSDX CHECKIN APPOINTMENT"
        },
        ihs_immunization: {
          "ImmunizationGateway.for_patient" => "BGOVIMM GET",
          "ImmunizationRefusalGateway.record" => "BGOREF SET",
          "EligibilityGateway.patient_eligibility" => "BGOVIMM GETVFC",
          "EligibilityGateway.list_codes" => "BGOVIMM2 GETELIG"
        }
      }.freeze

      STOCK_VISTA_GATEWAY_RPCS = {
        "EncounterGateway.for_patient" => "ORWPT APPTLST",
        "PatientGateway.find" => "ORWPT SELECT"
      }.freeze

      test "gated capability entry points are grounded on IHS-only RPC names" do
        assert_equal GATED_METHOD_IHS_RPC.keys.sort, BackendRegistry::CAPABILITIES.without(:pcc_screens).sort
        rpc_names = GATED_METHOD_IHS_RPC.values.flat_map(&:values)
        assert rpc_names.all? { |rpc| rpc.match?(/\A(BMC|AGG|BSDX|BGOVIMM|BGOREF|DDR)/) },
               "expected BMC/AG/BSDX/BGOVIMM/BGOREF/DDR RPCs only"
      end

      test "stock VistA scheduling and chart reads are listed as never gated by bprm_scheduling" do
        assert_equal "ORWPT APPTLST", STOCK_VISTA_GATEWAY_RPCS.fetch("EncounterGateway.for_patient")
      end

      test "RegistrationGateway register/update target AGG while PatientGateway stays on ORWPT" do
        reg = GATED_METHOD_IHS_RPC.fetch(:bprm_registration)
        assert reg.fetch("RegistrationGateway.register").start_with?("AGG")
        assert STOCK_VISTA_GATEWAY_RPCS.fetch("PatientGateway.find").start_with?("ORWPT")
      end
    end
  end
end
