# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/busa"

# lakeraven-ehr#617: BPRM 6.0 writes a BUSA security audit entry for audited
# actions (Core_SetBusaAuditLogQ, BUSA LOG SECURITY AUDIT ENTRY).
# SecurityAuditGateway wraps RpmsRpc::Busa.log_security_audit for the one
# audited action of this slice, a saved registration edit.
#
# BUSA records the signed-on user (DUZ) from the broker session, so the user is
# never a parameter. A reply that is not success is not a filed entry, and the
# caller is never raised at: the RPMS edit it follows has already happened.
# A DFN is sent only in the gem's canonical form (a positive whole number, or
# its digits with no leading zero); anything else is refused before any call.
module Lakeraven
  module EHR
    class SecurityAuditGatewayTest < ActiveSupport::TestCase
      DFN = 990_031
      DESCRIPTION = "Registration: demographics edited"

      # Stands in for RpmsRpc::Busa: records every call it is sent, then
      # answers from the script (a reply, or an exception to raise).
      class FakeBusa
        attr_reader :calls

        def initialize(reply)
          @reply = reply
          @calls = []
        end

        def log_security_audit(**pieces)
          @calls << pieces
          raise @reply if @reply.is_a?(Exception)

          @reply
        end
      end

      # As the gem does: a piece containing "|" is refused with ArgumentError
      # before anything is sent. `sent` holds only what would reach RPMS.
      class PipeRefusingBusa
        attr_reader :sent

        def initialize = @sent = []

        def log_security_audit(**pieces)
          raise ArgumentError, "BUSA audit pieces must not contain '|'" if pieces.values.any? { |piece| piece.to_s.include?("|") }

          @sent << pieces
          { success: true, message: "" }
        end
      end

      FILED = { success: true, message: "" }.freeze

      def record(via:, dfn: DFN, description: DESCRIPTION)
        SecurityAuditGateway.record_patient_edit(dfn: dfn, description: description, via: via)
      end

      def assert_not_filed(result)
        refute result.filed?, "expected the BUSA entry to be reported as not filed"
        assert_kind_of String, result.reason
        assert result.reason.strip.present?, "a not-filed result must say why"
      end

      test "sends one entry: category P, action E, the registration call name, the description and the DFN as detail" do
        fake = FakeBusa.new(FILED)

        record(via: fake)

        assert_equal [ { category: "P", action: "E", call: "LAKERAVEN EHR REGISTRATION",
                         description: DESCRIPTION, detail: "990031" } ], fake.calls
      end

      test "the user is not a parameter: BUSA takes the DUZ from the broker session" do
        fake = FakeBusa.new(FILED)

        record(via: fake)

        assert_equal 1, fake.calls.size
        assert_equal %i[action call category description detail], fake.calls.first.keys.sort
      end

      test "a DFN given as a string of digits is sent as that DFN" do
        fake = FakeBusa.new(FILED)

        result = record(via: fake, dfn: "990031")

        assert result.filed?
        assert_equal [ "990031" ], fake.calls.map { |call| call[:detail] }
      end

      test "is filed when RPMS answers success" do
        result = record(via: FakeBusa.new(FILED))

        assert result.filed?
      end

      test "is not filed when RPMS does not answer" do
        fake = FakeBusa.new(nil)

        result = record(via: fake)

        assert_equal 1, fake.calls.size, "RPMS must have been asked"
        assert_not_filed(result)
        assert_match(/did not answer/i, result.reason)
      end

      test "is not filed when RPMS refuses, and the reason is RPMS's message" do
        fake = FakeBusa.new({ success: false, message: "DUZ is not defined" })

        result = record(via: fake)

        assert_equal 1, fake.calls.size, "RPMS must have been asked"
        assert_not_filed(result)
        assert_includes result.reason, "DUZ is not defined"
      end

      # The live build answers 0^ with no message for a patient-detail row.
      test "is not filed when RPMS refuses without a message, and still says why" do
        fake = FakeBusa.new({ success: false, message: "" })

        result = record(via: fake)

        assert_equal 1, fake.calls.size, "RPMS must have been asked"
        assert_not_filed(result)
      end

      test "is not filed when the reply carries no success at all" do
        fake = FakeBusa.new({ message: "no result piece" })

        result = record(via: fake)

        assert_equal 1, fake.calls.size, "RPMS must have been asked"
        assert_not_filed(result)
      end

      [
        ::RpmsRpc::Client::RpcError.new("broker refused the call"),
        ArgumentError.new("bad piece"),
        StandardError.new("socket closed")
      ].each do |error|
        test "a #{error.class} from RPMS is returned as not filed, naming the exception class, never raised" do
          fake = FakeBusa.new(error)

          result = assert_nothing_raised { record(via: fake) }

          assert_equal 1, fake.calls.size, "RPMS must have been asked"
          assert_not_filed(result)
          assert_includes result.reason, error.class.name
        end
      end

      {
        "nil" => nil, "an empty string" => "", "the string 0" => "0", "letters" => "abc", "a fraction" => "12/3",
        "the integer 0" => 0, "a negative integer" => -5,
        # The gem's canonical DFN has no leading zero: "0990031" is not sent
        # as 990031, it is not sent.
        "digits with a leading zero" => "0990031", "zeros before a digit" => "007"
      }.each do |label, bad_dfn|
        test "a DFN that is #{label} is refused before RPMS is asked" do
          fake = FakeBusa.new(FILED)

          result = assert_nothing_raised { record(via: fake, dfn: bad_dfn) }

          assert_not_filed(result)
          assert_empty fake.calls, "BUSA must not be called without a patient"
        end
      end

      test "a description containing the piece delimiter is not filed, reaches RPMS in no form, and does not raise" do
        busa = PipeRefusingBusa.new

        result = assert_nothing_raised { record(via: busa, description: "Registration: demographics|edited") }

        assert_not_filed(result)
        assert_empty busa.sent
      end

      test "the same gateway and stand-in file a description without the delimiter" do
        busa = PipeRefusingBusa.new

        result = record(via: busa)

        assert result.filed?
        assert_equal 1, busa.sent.size
      end

      test "by default the entry goes through RpmsRpc::Busa" do
        calls = []
        restore = StubHelpers.install_singleton_stub(::RpmsRpc::Busa, :log_security_audit, nil)
        ::RpmsRpc::Busa.define_singleton_method(:log_security_audit) do |**pieces|
          calls << pieces
          { success: true, message: "" }
        end

        result = SecurityAuditGateway.record_patient_edit(dfn: DFN, description: DESCRIPTION)

        assert result.filed?
        assert_equal [ "990031" ], calls.map { |call| call[:detail] }
      ensure
        restore&.call
      end
    end
  end
end
