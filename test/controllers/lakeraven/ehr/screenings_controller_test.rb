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

      setup { sign_in }
      teardown do
        ScreeningResponse.delete_all
        AuditEvent.delete_all
      end

      def sign_in
        post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test" }
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
        }.merge(extra)
      end

      # -- The form ------------------------------------------------------------

      test "GET new renders every PHQ-9 item as a labelled radio group" do
        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }

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
        get "#{BASE}/new", params: { instrument: "gad-7" }

        assert_response :ok
        assert_select "fieldset.screening-item", 7
        assert_select "input[type=radio]", 28
      end

      test "the form carries no JavaScript" do
        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_no_match(/<script/i, response.body)
        assert_no_match(/onclick=/i, response.body)
      end

      test "an unknown instrument is a 404, not a blank form" do
        get "#{BASE}/new", params: { instrument: "phq-2" }

        assert_response :not_found
      end

      test "signing out closes the clinician surface" do
        delete "/lakeraven-ehr/logout"
        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_redirected_to "/lakeraven-ehr/login"
      end

      # -- Scoring -------------------------------------------------------------

      test "a complete submission is scored, stored and shown" do
        submit(answers: answers(PHQ9, [ 3, 2, 2, 2, 1, 1, 1, 0, 0 ]))

        record = ScreeningResponse.last
        assert_equal 12, record.total_score
        assert_equal "moderate", record.severity_band
        assert_redirected_to "#{BASE}/#{record.id}"

        follow_redirect!
        assert_response :ok
        assert_select ".screening-score__number", "12"
        assert_select ".screening-score__band", /Moderate/
      end

      test "the result page lists the item level responses" do
        submit(answers: answers(PHQ9, [ 3, 2, 2, 2, 1, 1, 1, 0, 0 ]))
        follow_redirect!

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
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-errors", /Visit required/
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
        follow_redirect!

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
        }

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
          get "#{BASE}/#{id}"
        end

        event = AuditEvent.recent.first
        assert_equal "R", event.action
        assert_equal "0", event.outcome
        assert_equal "99999", event.agent_who_identifier, "the acting DUZ must be on the audit row"
        assert_equal "1", event.entity_identifier
      end

      test "listing a patient's screenings is audited" do
        assert_difference -> { AuditEvent.count }, 1 do
          get BASE
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
        get "#{BASE}/999999"

        assert_response :not_found
        assert_equal "4", AuditEvent.recent.first.outcome
      end

      # -- Trending ------------------------------------------------------------

      test "the index lists a patient's screenings oldest first" do
        submit(answers: all_answered(PHQ9, 0))
        submit(instrument: GAD7, answers: all_answered(GAD7, 1))

        get BASE
        assert_response :ok
        assert_select "table.screening-history tbody tr", 2
        assert_select "table.screening-history tbody tr td", /PHQ-9/
        assert_select "table.screening-history tbody tr td", /GAD-7/
      end

      test "a screening belonging to another patient is not reachable by id" do
        submit
        id = ScreeningResponse.last.id

        get "/lakeraven-ehr/patients/2/screenings/#{id}"
        assert_response :not_found
      end
    end
  end
end
