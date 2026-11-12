# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # ProgressNoteService#sign against the answer the real e-signature gateway
    # gives (#1001). ESignatureGateway.validate passes on what
    # RpmsRpc::ESignature.validate returns, and that is true or false, not a
    # hash. A note written from the chart is signed through this service and
    # that gateway, so the service has to read a boolean.
    class ProgressNoteServiceSignatureCheckTest < ActiveSupport::TestCase
      NOTE_IEN = 7001
      DUZ = "99999"
      CODE = "SYNTH-SIG-CODE-1001"

      # Answers as ESignatureGateway does over the real provider.
      class BooleanESignatureGateway
        attr_reader :calls

        def initialize(accepts:, add: { success: true, raw: "0" })
          @accepts = accepts
          @add = add
          @calls = []
        end

        def validate(duz, code)
          @calls << [ :validate, duz.to_s, code ]
          @accepts
        end

        def add(note_ien, duz, code, action: :sign)
          @calls << [ :add, note_ien.to_s, duz.to_s, code, action ]
          @add
        end
      end

      def service(esignature)
        ProgressNoteService.new(dfn: "3", visit_ien: "501", author_duz: DUZ,
                                gateway: Object.new, esignature_gateway: esignature)
      end

      test "sign signs the note when the gateway answers true to the signature code" do
        esignature = BooleanESignatureGateway.new(accepts: true)

        result = service(esignature).sign(note_ien: NOTE_IEN, signature_code: CODE)

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal [ [ :validate, DUZ, CODE ], [ :add, NOTE_IEN.to_s, DUZ, CODE, :sign ] ], esignature.calls
      end

      test "sign refuses with invalid_signature_code, and never signs, when the gateway answers false" do
        esignature = BooleanESignatureGateway.new(accepts: false)

        result = service(esignature).sign(note_ien: NOTE_IEN, signature_code: CODE)

        refute result.success?
        assert_equal :invalid_signature_code, result.error
        assert_equal [ [ :validate, DUZ, CODE ] ], esignature.calls
      end

      test "sign reports a gateway error when signing is refused after the code was accepted" do
        esignature = BooleanESignatureGateway.new(accepts: true, add: { success: false, raw: "89250005^refused" })

        result = service(esignature).sign(note_ien: NOTE_IEN, signature_code: CODE)

        refute result.success?
        assert_equal :gateway_error, result.error
        assert_equal %i[validate add], esignature.calls.map(&:first)
      end
    end
  end
end
