# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The server-rendered clinician surface. Everything asserted here works
    # with JavaScript disabled: each guard is a plain POST that comes back as
    # a re-rendered form.
    class ScreeningsControllerTest < ActionDispatch::IntegrationTest
      PHQ9 = ScreeningInstrument::PHQ9
      GAD7 = ScreeningInstrument::GAD7
      BASE = "/lakeraven-ehr/patients/1/screenings"
      VISIT = "2090061"
      DUZ = "99999"
      FULL_SCOPES = "user/QuestionnaireResponse.read user/QuestionnaireResponse.write"

      setup do
        sign_in
        open_patient(1)
      end

      teardown do
        ScreeningResponse.delete_all
        AuditEvent.delete_all
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      # THE credential for this surface is the SMART token — the same one the
      # chart runs on, carrying scopes, expiry, revocation and the clinician's
      # DUZ. The session is where the patient context lives; it is not what
      # authorizes the read. (#486's sign-on bridge mints this token for a
      # browser session; here it is minted directly.)
      def token_for(scopes: FULL_SCOPES, duz: DUZ)
        app = Doorkeeper::Application.create!(
          name: "screening-test", redirect_uri: "https://example.test/callback",
          scopes: scopes, confidential: true
        )
        Doorkeeper::AccessToken.create!(
          application: app, scopes: scopes, resource_owner_id: duz, expires_in: 3600
        )
      end

      def auth_headers(token = nil)
        token ||= (@token ||= token_for)
        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      def sign_in(scopes: FULL_SCOPES, duz: DUZ)
        @token = token_for(scopes: scopes, duz: duz)
      end

      # The clinician's session is bound to a patient by an explicit, audited
      # act — reading a record is not what opens it.
      def open_patient(dfn)
        post "/lakeraven-ehr/patients/#{dfn}/context", headers: auth_headers
      end

      # `follow_redirect!` replays the request WITHOUT headers, and the
      # credential for this surface lives in one.
      def follow_redirect_authorized!
        get response.location, headers: auth_headers
      end

      # Minitest 6 dropped `minitest/mock`, so a failure is injected by
      # swapping the singleton method and putting back exactly what was there —
      # a scope defined on the class itself is restored, not deleted.
      def with_failing(klass, method, replacement)
        singleton = klass.singleton_class
        original = singleton.instance_method(method) if singleton.method_defined?(method)
        original = nil unless original&.owner == singleton

        klass.define_singleton_method(method, &replacement)
        yield
      ensure
        singleton.send(:remove_method, method)
        singleton.send(:define_method, method, original) if original
      end

      def with_broken_audit(&block)
        with_failing(AuditEvent, :create!,
                     ->(*) { raise ActiveRecord::StatementInvalid, "audit down" }, &block)
      end

      def answers(instrument, values) = instrument.link_ids.zip(values).to_h
      def all_answered(instrument, value) = instrument.link_ids.index_with { value }

      # Complete, with the self-harm item at "not at all" — the default for
      # tests that are not about the safety gate.
      def complete_without_safety_flag(instrument)
        answers = all_answered(instrument, 1)
        answers[instrument.safety_link_id] = 0 if instrument.safety_item?
        answers
      end

      def submit(instrument: PHQ9, answers: nil, **extra)
        post BASE, params: {
          instrument: instrument.key,
          encounter_ien: VISIT,
          answers: answers || complete_without_safety_flag(instrument)
        }.merge(extra), headers: auth_headers
      end

      # -- The form ------------------------------------------------------------

      test "GET new renders every PHQ-9 item as a labelled radio group" do
        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }, headers: auth_headers

        assert_response :ok
        assert_select "fieldset.screening-item", 9
        assert_select "legend", /Little interest or pleasure in doing things/
        # Four choices per item, each with an explicit label bound to its input.
        assert_select "input[type=radio]", 36
        PHQ9.link_ids.each do |link_id|
          assert_select "input[type=radio][name=?]", "answers[#{link_id}]", 4
          assert_select "label[for=?]", "answer-#{link_id}-0"
        end
      end

      test "GET new renders the seven GAD-7 items" do
        get "#{BASE}/new", params: { instrument: "gad-7" }, headers: auth_headers

        assert_response :ok
        assert_select "fieldset.screening-item", 7
        assert_select "input[type=radio]", 28
      end

      test "the form carries no JavaScript" do
        get "#{BASE}/new", params: { instrument: "phq-9" }, headers: auth_headers

        assert_no_match(/<script/i, response.body)
        assert_no_match(/onclick=/i, response.body)
      end

      test "an unknown instrument is a 404, not a blank form" do
        get "#{BASE}/new", params: { instrument: "phq-2" }, headers: auth_headers

        assert_response :not_found
      end

      # -- The credential: one story with the FHIR surface (#486) --------------
      #
      # This surface used to authorize on `session[:user_type]` and hide the
      # token, so none of the token's controls applied to it: a keyless
      # provider holding an empty-scope token could read self-harm answers.
      # It now runs on the SAME credential as the chart.

      test "no token closes the surface" do
        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :unauthorized
        assert_no_match(/Little interest or pleasure/, response.body)
      end

      test "a revoked token closes the surface" do
        token = token_for
        token.update!(revoked_at: Time.current)

        get "#{BASE}/new", params: { instrument: "phq-9" }, headers: auth_headers(token)

        assert_response :unauthorized
      end

      test "an expired token closes the surface" do
        token = token_for
        token.update!(created_at: 2.days.ago, expires_in: 60)

        get "#{BASE}/new", params: { instrument: "phq-9" }, headers: auth_headers(token)

        assert_response :unauthorized
      end

      test "a token with no QuestionnaireResponse scope cannot read the answers" do
        submit
        id = ScreeningResponse.last.id
        keyless = token_for(scopes: "user/Patient.read")

        get "#{BASE}/#{id}", headers: auth_headers(keyless)

        assert_response :forbidden
        assert_no_match(/#{SELF_HARM_ITEM_TEXT}/i, response.body)
      end

      test "an empty-scope token — a keyless provider — reads nothing" do
        submit
        id = ScreeningResponse.last.id
        keyless = token_for(scopes: "")

        get "#{BASE}/#{id}", headers: auth_headers(keyless)

        assert_response :forbidden
      end

      test "a read scope does not authorize recording a screening" do
        read_only = token_for(scopes: "user/QuestionnaireResponse.read")

        assert_no_difference -> { ScreeningResponse.count } do
          post BASE, params: {
            instrument: PHQ9.key, encounter_ien: VISIT,
            answers: complete_without_safety_flag(PHQ9)
          }, headers: auth_headers(read_only)
        end
        assert_response :forbidden
      end

      test "a patient-scoped token bound to another patient cannot read this one" do
        submit
        id = ScreeningResponse.last.id
        other = token_for(scopes: "patient/QuestionnaireResponse.read", duz: "2")

        get "#{BASE}/#{id}", headers: auth_headers(other)

        assert_response :forbidden
      end

      # -- Scoring -------------------------------------------------------------

      test "a complete submission is scored, stored and shown" do
        submit(answers: answers(PHQ9, [ 3, 2, 2, 2, 1, 1, 1, 0, 0 ]))

        record = ScreeningResponse.last
        assert_equal 12, record.total_score
        assert_equal "moderate", record.severity_band
        assert_redirected_to "#{BASE}/#{record.id}"

        follow_redirect_authorized!
        assert_response :ok
        assert_select ".screening-score__number", "12"
        # Anchored: /Moderate/ also matches "Moderately severe", the band this
        # feature most needs to tell apart from "Moderate".
        assert_select ".screening-score__band", text: /\ASeverity band: Moderate\z/
      end

      test "the result page names the moderately severe band in full" do
        submit(answers: answers(PHQ9, [ 3, 3, 3, 3, 2, 2, 2, 0, 0 ]))
        follow_redirect_authorized!

        assert_equal 18, ScreeningResponse.last.total_score
        assert_select ".screening-score__band", text: /\ASeverity band: Moderately severe\z/
      end

      test "the result page lists the item level responses" do
        submit(answers: answers(PHQ9, [ 3, 2, 2, 2, 1, 1, 1, 0, 0 ]))
        follow_redirect_authorized!

        assert_select "table.screening-responses tbody tr", 9
        assert_select "table.screening-responses tfoot td", "12"
      end

      # -- Incomplete ----------------------------------------------------------

      test "an incomplete submission re-renders the form, names the items and stores nothing" do
        missing = [ PHQ9.items[2].link_id, PHQ9.items[7].link_id ]
        submit(answers: all_answered(PHQ9, 1).except(*missing))

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-errors[role=alert] li", 2
        assert_select ".screening-errors", /not scored/i
        missing.each do |link_id|
          assert_select "fieldset##{'item-' + link_id}[aria-invalid=true]"
          assert_select "a[href=?]", "#item-#{link_id}"
        end
      end

      test "answers already given survive the re-render" do
        submit(answers: { PHQ9.items[0].link_id => 3, PHQ9.items[1].link_id => 2 })

        assert_response :unprocessable_entity
        assert_select "input[type=radio][id=?][checked]", "answer-#{PHQ9.items[0].link_id}-3"
        assert_select "input[type=radio][id=?][checked]", "answer-#{PHQ9.items[1].link_id}-2"
      end

      test "a submission without a visit re-renders rather than saving" do
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }, headers: auth_headers

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-errors", /Visit required/
      end

      test "a submission missing both the visit and answers names both" do
        missing = [ PHQ9.items[2].link_id, PHQ9.items[7].link_id ]
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1).except(*missing) },
             headers: auth_headers

        assert_response :unprocessable_entity
        assert_select ".screening-errors", /Visit required/
        assert_select ".screening-errors", /not scored/i
        assert_select ".screening-errors[role=alert] li", 2
      end

      # -- Idempotency ---------------------------------------------------------

      test "a resubmitted form does not create a second administration" do
        submit
        first_id = ScreeningResponse.last.id

        assert_no_difference -> { ScreeningResponse.count } do
          submit
        end
        assert_redirected_to "#{BASE}/#{first_id}"
      end

      # -- Item 9 safety prompt ------------------------------------------------

      test "a positive item 9 surfaces the safety prompt and blocks the save" do
        submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2))

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-safety[role=alert]"
        assert_select ".screening-safety h2", /Safety check required/
        assert_select "input[type=checkbox][name=safety_acknowledged]"
        assert_select "label[for=safety_acknowledged]"
      end

      test "the safety prompt is server-rendered, needing no JavaScript" do
        submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 1))

        # The page shape is only half the claim: the prompt must also have
        # BLOCKED the save, or a scriptless client is being shown a warning
        # about a record that is already in the table.
        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_no_match(/<script/i, response.body)
        assert_select "form input[name=safety_acknowledged]"
      end

      test "acknowledging the prompt on resubmission saves the screening" do
        positive = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        submit(answers: positive)
        assert_equal 0, ScreeningResponse.count

        submit(answers: positive, safety_acknowledged: "1")

        record = ScreeningResponse.last
        assert_not_nil record
        assert_equal 2, record.total_score
        assert record.safety_flagged?
      end

      test "the stored result repeats the safety guidance" do
        submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 3), safety_acknowledged: "1")
        follow_redirect_authorized!

        assert_select ".screening-safety h2", /Self-harm response recorded/
      end

      # At HTTP, on the FIRST submission, with the prompt never shown: a
      # hand-crafted (or mis-rendered) acknowledgement value must not persist a
      # self-harm disclosure.
      [ "false", "0", "" ].each do |value|
        test "safety_acknowledged=#{value.inspect} over HTTP does not bypass the prompt" do
          submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 3),
                 safety_acknowledged: value)

          assert_response :unprocessable_entity
          assert_equal 0, ScreeningResponse.count
          assert_select ".screening-safety[role=alert]"
        end
      end

      test "the array param form of safety_acknowledged does not bypass the prompt" do
        post BASE, params: {
          instrument: PHQ9.key,
          encounter_ien: VISIT,
          answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 3),
          safety_acknowledged: [ "false" ]
        }, headers: auth_headers

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-safety[role=alert]"
      end

      test "a GAD-7 with every item maxed needs no safety acknowledgement" do
        submit(instrument: GAD7, answers: all_answered(GAD7, 3))

        assert_equal 21, ScreeningResponse.last.total_score
      end

      # -- Audit (the policy every FHIR controller and the chart follow) --------

      test "reading a screening result is audited against the clinician and the patient" do
        submit
        id = ScreeningResponse.last.id
        AuditEvent.delete_all

        assert_difference -> { AuditEvent.count }, 1 do
          get "#{BASE}/#{id}", headers: auth_headers
        end

        event = AuditEvent.recent.first
        assert_equal "R", event.action
        assert_equal "0", event.outcome
        assert_equal "99999", event.agent_who_identifier, "the acting DUZ must be on the audit row"
        assert_equal "1", event.entity_identifier
      end

      test "listing a patient's screenings is audited" do
        assert_difference -> { AuditEvent.count }, 1 do
          get BASE, headers: auth_headers
        end

        assert_equal "1", AuditEvent.recent.first.entity_identifier
      end

      test "recording a screening is audited as a create" do
        assert_difference -> { AuditEvent.count }, 1 do
          submit
        end

        assert_equal "C", AuditEvent.recent.first.action
      end

      test "a refused read is audited with a failure outcome" do
        get "#{BASE}/999999", headers: auth_headers

        assert_response :not_found
        assert_equal "4", AuditEvent.recent.first.outcome
      end

      # -- Audit fails CLOSED ---------------------------------------------------
      #
      # If an access cannot be recorded, the access does not happen. An audit
      # written after the fact, best-effort, is not a control: it returned the
      # PHI whether or not the row landed, and a refusal — the access most
      # worth recording — produced no row at all because the after_action
      # never ran.

      test "PHI is not returned when the access cannot be recorded" do
        submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 3),
               safety_acknowledged: "1")
        id = ScreeningResponse.last.id

        with_broken_audit do
          get "#{BASE}/#{id}", headers: auth_headers
        end

        assert_response :service_unavailable
        assert_no_match(/#{SELF_HARM_ITEM_TEXT}/i, response.body)
        assert_no_match(/Nearly every day/i, response.body)
      end

      test "a patient record is not opened when the open cannot be recorded" do
        reset!
        sign_in

        with_broken_audit { open_patient(1) }
        assert_response :service_unavailable

        get BASE, headers: auth_headers
        assert_response :forbidden, "an unrecorded open must not leave the record open"
      end

      test "a refusal is audited, not only a success" do
        reset!
        sign_in

        assert_difference -> { AuditEvent.count }, 1 do
          get BASE, headers: auth_headers # patient context never opened -> 403
        end

        assert_response :forbidden
        assert_equal "4", AuditEvent.recent.first.outcome
        assert_equal DUZ, AuditEvent.recent.first.agent_who_identifier
      end

      test "an exception on the way to the data is audited as a serious failure" do
        with_failing(ScreeningResponse, :for_patient, ->(*) { raise "gateway exploded" }) do
          assert_raises(RuntimeError) { get BASE, headers: auth_headers }
        end

        assert_equal "8", AuditEvent.recent.first.outcome
      end

      # -- Trending ------------------------------------------------------------

      test "the index lists a patient's screenings oldest first" do
        submit(answers: all_answered(PHQ9, 0))
        submit(instrument: GAD7, answers: all_answered(GAD7, 1))

        get BASE, headers: auth_headers
        assert_response :ok
        assert_select "table.screening-history tbody tr", 2
        assert_select "table.screening-history tbody tr td", /PHQ-9/
        assert_select "table.screening-history tbody tr td", /GAD-7/
      end

      # -- Authorization -------------------------------------------------------

      # The item text and the chosen answers are the most sensitive content in
      # the feature, and this route's :id is published in the chart bundle as
      # part of the deterministic Observation id (`screening-phq-9-68`), so a
      # signed-in session must not be able to walk it.
      SELF_HARM_ITEM_TEXT = "better off dead"

      test "a signed-in clinician cannot read a screening for a patient the session never opened" do
        submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 3),
               safety_acknowledged: "1")
        id = ScreeningResponse.last.id

        # A second, freshly signed-in session that never opened patient 1.
        reset!
        sign_in
        get "#{BASE}/#{id}", headers: auth_headers

        assert_response :forbidden
        assert_no_match(/#{SELF_HARM_ITEM_TEXT}/i, response.body)
        assert_no_match(/Nearly every day/i, response.body)
      end

      test "the screening history is closed to a patient the session never opened" do
        submit
        reset!
        sign_in
        get BASE, headers: auth_headers

        assert_response :forbidden
        assert_no_match(/PHQ-9/, response.body)
      end

      test "opening one patient does not open another" do
        submit
        id = ScreeningResponse.last.id
        reset!
        sign_in
        open_patient(2)
        get "/lakeraven-ehr/patients/1/screenings/#{id}", headers: auth_headers

        assert_response :forbidden
      end

      # Names what it actually proves: the query is scoped by dfn. The
      # AUTHORIZATION claim is the test above it — this one would pass with
      # none at all, which is how it read before.
      test "a screening id from one patient is not served under another patient's dfn" do
        submit
        id = ScreeningResponse.last.id

        open_patient(2)
        get "/lakeraven-ehr/patients/2/screenings/#{id}", headers: auth_headers

        assert_response :not_found
        assert_no_match(/#{SELF_HARM_ITEM_TEXT}/i, response.body)
      end

      test "recording a screening for an unopened patient is refused" do
        reset!
        sign_in

        assert_no_difference -> { ScreeningResponse.count } do
          submit
        end
        assert_response :forbidden
      end

      test "opening a patient record is an explicit act, and it is audited" do
        reset!
        sign_in

        assert_difference -> { AuditEvent.count }, 1 do
          open_patient(1)
        end

        event = AuditEvent.recent.first
        assert_equal "99999", event.agent_who_identifier
        assert_equal "1", event.entity_identifier
      end

      # A gate that opens itself is not a gate: the refused read must not be
      # what establishes the context.
      test "a refused read does not itself open the record" do
        submit
        id = ScreeningResponse.last.id
        reset!
        sign_in

        get "#{BASE}/#{id}", headers: auth_headers
        assert_response :forbidden
        get "#{BASE}/#{id}", headers: auth_headers
        assert_response :forbidden
      end

      # -- Legacy rows must not take the clinician surface down ----------------

      test "a row naming an unknown instrument does not 500 the history" do
        submit
        ScreeningResponse.last.update_column(:instrument_key, "phq-2")

        get BASE, headers: auth_headers

        assert_response :ok
        assert_select "table.screening-history tbody tr", 0
      end

      test "a row naming an unknown instrument does not 500 its own page" do
        submit
        id = ScreeningResponse.last.id
        ScreeningResponse.last.update_column(:instrument_key, "phq-2")

        get "#{BASE}/#{id}", headers: auth_headers

        assert_response :unprocessable_entity
        assert_match(/cannot be displayed/i, response.body)
      end

      test "a row that contradicts its own answers is not displayed as a result" do
        submit
        id = ScreeningResponse.last.id
        ScreeningResponse.last.update_column(:total_score, 999)

        get "#{BASE}/#{id}", headers: auth_headers

        assert_response :unprocessable_entity
        assert_no_match(/999/, response.body)
      end
    end
  end
end
