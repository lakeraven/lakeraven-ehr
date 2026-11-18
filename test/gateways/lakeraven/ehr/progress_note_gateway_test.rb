# frozen_string_literal: true

require "test_helper"
require "digest"

# Tests for ProgressNoteGateway — TIU progress note create, list, fetch,
# edit, lock. Signing lives in ESignatureGateway, not here.
# Wraps RpmsRpc::ProgressNote (lakeraven/rpms-rpc#57).
module Lakeraven
  module EHR
    class ProgressNoteGatewayTest < ActiveSupport::TestCase
      class FakeProgressNoteAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def create(dfn, visit_ien, title_ien)
          @calls << { method: :create, args: [ dfn, visit_ien, title_ien ] }
          @returns[:create] || { success: true, ien: 1001, raw: "1001" }
        end

        def list(dfn, context: :all)
          @calls << { method: :list, args: [ dfn ], context: context }
          @returns[:list] || []
        end

        def fetch_text(note_ien)
          @calls << { method: :fetch_text, args: [ note_ien ] }
          @returns[:fetch_text]
        end

        def update_text(note_ien, text)
          @calls << { method: :update_text, args: [ note_ien, text ] }
          @returns[:update_text] || { success: true, raw: "0" }
        end
      end

      # --- via: nil ---

      test "create returns failure shape when no provider is available" do
        assert_equal({ success: false, ien: nil, raw: nil },
          ProgressNoteGateway.create(1, 2090061, 4321, via: nil))
      end

      test "list returns empty when no provider is available" do
        assert_equal [], ProgressNoteGateway.list(1, via: nil)
      end

      test "fetch_text returns nil when no provider is available" do
        assert_nil ProgressNoteGateway.fetch_text(1001, via: nil)
      end

      test "authorize returns false when no provider is available" do
        refute ProgressNoteGateway.authorize(1001, via: nil)
      end

      test "lock returns false when no provider is available" do
        refute ProgressNoteGateway.lock(1001, via: nil)
      end

      test "update_text returns failure shape when no provider is available" do
        assert_equal({ success: false, raw: nil },
          ProgressNoteGateway.update_text(1001, "S: ...", via: nil))
      end

      test "unlock returns false when no provider is available" do
        refute ProgressNoteGateway.unlock(1001, via: nil)
      end

      # --- delegation + coercion ---

      test "create delegates with all identifiers coerced to strings" do
        fake = FakeProgressNoteAPI.new(returns: { create: { success: true, ien: 5050, raw: "5050" } })

        result = ProgressNoteGateway.create(1, 2090061, 4321, via: fake)

        assert_equal({ success: true, ien: 5050, raw: "5050" }, result)
        assert_equal [ "1", "2090061", "4321" ], fake.calls.first[:args]
      end

      test "list passes the context symbol through unchanged" do
        fake = FakeProgressNoteAPI.new(returns: { list: [ { ien: 1, title: "Office Visit" } ] })

        result = ProgressNoteGateway.list(1, context: :unsigned, via: fake)

        assert_equal 1, result.length
        assert_equal :unsigned, fake.calls.first[:context]
      end

      test "list defaults to :all when context is omitted" do
        fake = FakeProgressNoteAPI.new(returns: { list: [] })

        ProgressNoteGateway.list(1, via: fake)

        assert_equal :all, fake.calls.first[:context]
      end

      test "fetch_text delegates" do
        fake = FakeProgressNoteAPI.new(returns: { fetch_text: "S: HPI..." })

        assert_equal "S: HPI...", ProgressNoteGateway.fetch_text(1001, via: fake)
        assert_equal [ "1001" ], fake.calls.first[:args]
      end

      # Replies as a fresh rpms-ydb e9b78c8 sent them for note 5 (a completed
      # TELEPHONE NOTE on DFN 4), replayed through the real RpmsRpc::ProgressNote,
      # so a change to the gem's signature fails here. The note is completed, so
      # CANDO refuses EDIT RECORD with its own reason (TIUSRVA.m:23-29).
      test "authorize asks for EDIT RECORD as the signed-on user and reads the refusal" do
        RpmsRpc.client.seed_raw_lines(:tiu_authorization, "5", [ "0^ You may not edit uncosigned or completed documents" ])

        refute ProgressNoteGateway.authorize(5)
        assert_equal [ "5", "EDIT RECORD" ], RpmsRpc.client.received_calls.last[:params]
      end

      test "lock and unlock send the note alone and read RPMS's 0 as done" do
        RpmsRpc.client.seed_raw_lines(:tiu_lock_record, "5", [ "0" ])
        RpmsRpc.client.seed_raw_lines(:tiu_unlock_record, "5", [ "0" ])

        assert ProgressNoteGateway.lock(5)
        assert_equal [ "5" ], RpmsRpc.client.received_calls.last[:params]
        assert ProgressNoteGateway.unlock(5)
        assert_equal [ "5" ], RpmsRpc.client.received_calls.last[:params]
      end

      test "update_text delegates and preserves the 2-key success shape" do
        fake = FakeProgressNoteAPI.new(returns: { update_text: { success: true, raw: "0" } })

        result = ProgressNoteGateway.update_text(1001, "S: revised note text", via: fake)

        assert_equal({ success: true, raw: "0" }, result)
        assert_equal [ "1001", "S: revised note text" ], fake.calls.first[:args]
      end

      # --- fetch_body (lakeraven-ehr#960) ---
      #
      # TIU GET RECORD TEXT returns a display: header rows, ONE blank row, the
      # body rows, and, once the note is signed, a signature block after the
      # body. Only the body is evidence of what was signed. The layout follows
      # the gem's live capture (tiu-get-record-text.yml); the text is synthetic.

      BODY_ROWS = [
        "S: Synthetic cough for two days, no fever.",
        "P: Synthetic plan: fluids and rest; return if worse."
      ].freeze

      def tiu_header(status:)
        [
          " LOCAL TITLE: Synthetic Clinic Note                                 ",
          "STANDARD TITLE: SYNTHETIC OUTPATIENT NOTE                           ",
          "DATE OF NOTE: NOV 15, 2026@09:30:00  ENTRY DATE: NOV 15, 2026@09:30:00      ",
          "      AUTHOR: PROVIDER,SYNTHETIC   EXP COSIGNER:                           ",
          "     URGENCY:                            STATUS: #{status}                      "
        ]
      end

      SIGNATURE_BLOCK = [ "", "/es/ PROVIDER,SYNTHETIC", "Signed: 11/15/2026 10:00" ].freeze

      # The wire shape: rows separated by +separator+, with a trailing one.
      def tiu_text(status: "UNSIGNED", body: BODY_ROWS, signature: [], separator: "\r")
        (tiu_header(status: status) + [ "" ] + body + signature).join(separator) + separator
      end

      def fetch_body_of(text)
        ProgressNoteGateway.fetch_body(1001, via: FakeProgressNoteAPI.new(returns: { fetch_text: text }))
      end

      test "fetch_body returns nil when no provider is available" do
        assert_nil ProgressNoteGateway.fetch_body(1001, via: nil)
      end

      test "fetch_body reads the text through fetch_text with the note IEN as a string" do
        fake = FakeProgressNoteAPI.new(returns: { fetch_text: tiu_text })

        ProgressNoteGateway.fetch_body(1001, via: fake)

        assert_equal [ { method: :fetch_text, args: [ "1001" ] } ], fake.calls
      end

      test "fetch_body returns exactly the body rows of the capture-shaped text" do
        text = tiu_text
        assert text.end_with?("\r"), "the capture ends with a row separator"
        assert_includes text, "STATUS: UNSIGNED"

        assert_equal BODY_ROWS, fetch_body_of(text)
      end

      test "fetch_body returns nil for nil text" do
        assert_nil fetch_body_of(nil)
      end

      test "fetch_body returns nil for text with no blank row: an unrecognised shape is not evidence" do
        text = (tiu_header(status: "UNSIGNED") + BODY_ROWS).join("\r")

        assert_nil fetch_body_of(text)
      end

      test "fetch_body returns nil for body-only text with no header blank" do
        assert_nil fetch_body_of("S: Synthetic body with no header.")
      end

      test "fetch_body splits on CRLF and LF as well as CR" do
        assert_equal BODY_ROWS, fetch_body_of(tiu_text(separator: "\r\n"))
        assert_equal BODY_ROWS, fetch_body_of(tiu_text(separator: "\n"))
      end

      test "fetch_body splits only at the first blank row and keeps blank rows inside the body" do
        body = [ "S: Synthetic first paragraph.", "", "P: Synthetic second paragraph." ]

        assert_equal body, fetch_body_of(tiu_text(body: body))
      end

      # The wire text ends with a delimiter, so splitting it leaves one empty
      # element after the last row. Only that one is transport; an empty row
      # before it is a row of the note, and the record hash must see it.
      test "fetch_body drops only the final delimiter's empty element and keeps empty rows before it" do
        plain = fetch_body_of(tiu_text)
        with_blank_rows = fetch_body_of(tiu_text + "\r\r")

        assert_equal BODY_ROWS, plain
        assert_equal BODY_ROWS + [ "", "" ], with_blank_rows
        refute_equal plain, with_blank_rows
      end

      test "fetch_body returns an empty body when nothing follows the header blank" do
        assert_equal [], fetch_body_of(tiu_text(body: []))
      end

      # The header separator is the first row that is empty AFTER STRIP: a
      # row of spaces separates like an empty one.
      test "fetch_body treats a whitespace-only row as the header separator" do
        text = [ "     URGENCY:          STATUS: UNSIGNED", " ", "A", "", "B" ].join("\r")

        assert_equal [ "A", "", "B" ], fetch_body_of(text)
      end

      test "fetch_body separates at a whitespace-only row that comes before an empty one" do
        text = (tiu_header(status: "UNSIGNED") + [ "   \t" ] + BODY_ROWS + [ "", "P: Synthetic later paragraph." ]).join("\r")

        assert_equal BODY_ROWS + [ "", "P: Synthetic later paragraph." ], fetch_body_of(text)
      end

      test "fetch_body returns nil for a header with no blank or whitespace-only row" do
        assert_nil fetch_body_of(tiu_header(status: "UNSIGNED").join("\r"))
      end

      # What the signing audit records and what a verifier does with it
      # (#960). content is the body read before signing; record is the body
      # read after it, signature block included. The verifier hashes ALL the
      # rows of a later read and compares them with the record hash.
      def body_hash(rows) = Digest::SHA256.hexdigest(rows.join("\n"))

      def signed_text(body: BODY_ROWS, signature: SIGNATURE_BLOCK)
        tiu_text(status: "COMPLETED", body: body, signature: signature)
      end

      test "signing changes the header and appends a signature block after the unchanged body rows" do
        unsigned = fetch_body_of(tiu_text(status: "UNSIGNED"))

        refute_includes signed_text, "STATUS: UNSIGNED"
        signed = fetch_body_of(signed_text)

        assert_equal BODY_ROWS + SIGNATURE_BLOCK, signed
        assert_equal unsigned, signed.first(unsigned.size)
        refute_equal body_hash(unsigned), body_hash(signed), "the record hash is not the content hash"
      end

      test "an unchanged signed note re-read later reproduces the record hash over all its rows" do
        record_hash = body_hash(fetch_body_of(signed_text))

        assert_equal record_hash, body_hash(fetch_body_of(signed_text))
        assert_equal record_hash, body_hash(fetch_body_of(signed_text.tr("\r", "\n")))
      end

      # The append-blind check: hashing only the first content-rows rows
      # passes this note. Hashing all rows against the record hash does not.
      test "rows appended after signing no longer reproduce the record hash" do
        content = fetch_body_of(tiu_text(status: "UNSIGNED"))
        record_hash = body_hash(fetch_body_of(signed_text))

        appended = fetch_body_of(signed_text(signature: SIGNATURE_BLOCK + [ "Addendum: synthetic row appended later." ]))

        assert_equal body_hash(content), body_hash(appended.first(content.size)),
                     "the first content-rows rows alone do not show the append"
        refute_equal record_hash, body_hash(appended)
      end

      test "one blank row appended after filing no longer reproduces the record hash" do
        content = fetch_body_of(tiu_text(status: "UNSIGNED"))
        record_hash = body_hash(fetch_body_of(signed_text))

        appended = fetch_body_of(signed_text(signature: SIGNATURE_BLOCK + [ "" ]))

        assert_equal body_hash(content), body_hash(appended.first(content.size)),
                     "the first content-rows rows alone do not show the append"
        refute_equal record_hash, body_hash(appended)
      end

      test "a signed note whose body was altered no longer reproduces the record hash" do
        record_hash = body_hash(fetch_body_of(signed_text))

        altered = [ BODY_ROWS.first, "P: Synthetic plan, altered after signing." ]

        refute_equal record_hash, body_hash(fetch_body_of(signed_text(body: altered)))
      end

      test "a signed note that lost a row no longer reproduces the record hash" do
        record_hash = body_hash(fetch_body_of(signed_text))

        refute_equal record_hash, body_hash(fetch_body_of(signed_text(signature: SIGNATURE_BLOCK[0..-2])))
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::ProgressNote when the gem ships it" do
        provider = ProgressNoteGateway.default_provider
        refute_nil provider, "expected RpmsRpc::ProgressNote to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::ProgressNote", provider.name
      end
    end
  end
end
