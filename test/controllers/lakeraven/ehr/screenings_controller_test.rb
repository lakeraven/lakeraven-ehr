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
      DFN_PARAM = "1"
      # Without the visit list a screening cannot be attached to a visit at all
      # (#1003): the form offers the patient's open visits and create accepts
      # only one of them, so the clinician's credential reads Encounter too.
      SCREENING_ONLY_SCOPES = "user/QuestionnaireResponse.read user/QuestionnaireResponse.write"
      FULL_SCOPES = "#{SCREENING_ONLY_SCOPES} user/Encounter.read".freeze
      # Synthetic names only.
      CLINIC = "Riverbend Behavioral Health"
      PROVIDER = "TESTPROVIDER,ALPHA"
      OTHER_DFN = "2"
      OTHER_PATIENT_VISIT = "5550077"

      setup do
        # #486's landing contract: a session-derived credential may only
        # write where CSRF protection is actually enforced. The test
        # environment disables forgery protection globally, which would turn
        # every session write into a refusal — so it is ON for this class,
        # and every POST carries a real authenticity token, exactly as the
        # surface runs in production.
        @forgery_was = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        sign_in
        open_patient(1)
        # The visit every existing test records against: open, checked in today.
        seed_visits(DFN_PARAM, [ visit_row(VISIT, at: today_at(9, 30)) ])
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @forgery_was
        ScreeningResponse.delete_all
        AuditEvent.delete_all
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      # THE credential for this surface is the SMART token — the same one the
      # chart runs on, carrying scopes, expiry, revocation and the clinician's
      # DUZ. The session is where the patient context lives AND how a browser
      # token travels: #486 binds a browser credential to the session that
      # minted it, so presenting one from an Authorization header is refused
      # by design. These tests authenticate the way a browser actually does.
      #
      # A CLINICIAN credential is specifically a browser sign-on token (#486
      # mints these; the intrinsic `browser_session` flag is how they are
      # recognised), whose `resource_owner_id` is a DUZ. That field is
      # polymorphic in this codebase — on a `patient/` token it is a patient
      # dfn — so the two are minted by different helpers here and must never
      # be interchangeable.
      def token_for(scopes: FULL_SCOPES, duz: DUZ,
                    app_name: SmartAuthentication::BROWSER_SSO_APP_NAME)
        app = Doorkeeper::Application.create!(
          name: app_name, redirect_uri: "https://example.test/callback",
          scopes: scopes, confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: app, scopes: scopes, resource_owner_id: duz, expires_in: 3600
        )
        if app_name == SmartAuthentication::BROWSER_SSO_APP_NAME && token.has_attribute?(:browser_session)
          token.update_column(:browser_session, true)
        end
        token
      end

      # A patient-context credential: `resource_owner_id` is the PATIENT, not a
      # clinician, and it is not minted by the sign-on bridge.
      def patient_token(dfn: "1", scopes: "patient/QuestionnaireResponse.read patient/QuestionnaireResponse.write")
        token_for(scopes: scopes, duz: dfn, app_name: "smart-patient-app")
      end

      # A backend/system credential: no human behind it at all.
      def system_token(scopes: "system/QuestionnaireResponse.read system/QuestionnaireResponse.write")
        token_for(scopes: scopes, duz: nil, app_name: "backend-service")
      end

      # Non-browser credentials (patient- and system-scoped) are bearer
      # credentials and still arrive in a header. The signed-in clinician's
      # browser credential rides the session, so it needs no header at all.
      def auth_headers(token = nil)
        return {} if token.nil?

        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      # Establish the browser session the way the sign-on bridge does (#486):
      # the SMART token is stashed in the session, bound to the session's DUZ.
      def sign_in(scopes: FULL_SCOPES, duz: DUZ)
        @token = token_for(scopes: scopes, duz: duz)
        post "/lakeraven-ehr/test_session", params: {
          duz: duz, user_type: "provider",
          smart_token: @token.plaintext_token || @token.token
        }
        @csrf = nil
        csrf_param # scrape eagerly, so audit-count assertions see no extra GET
      end

      # A session-valid authenticity token, scraped from the login page's META
      # tag (per-form tokens are bound to one form; the meta token is the
      # session-wide one) — forgery protection is ON for this class.
      def csrf_param
        @csrf ||= begin
          get "/lakeraven-ehr/login"
          { authenticity_token: css_select("meta[name=csrf-token]").first&.[]("content") }
        end
      end

      # The clinician's session is bound to a patient by an explicit, audited
      # act — reading a record is not what opens it.
      def open_patient(dfn)
        post "/lakeraven-ehr/patients/#{dfn}/context", params: csrf_param
      end

      # The credential rides the session, which `follow_redirect!` keeps.
      def follow_redirect_authorized!
        get response.location
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

      # -- Visits (BEHOENCX VISITLST, through EncounterGateway.visits) ----------

      # One VISITLST row. The fourth piece of the visit string is the visit
      # IEN; a row without it is an appointment pending check-in, not a visit.
      def visit_row(ien, at:, clinic: CLINIC, provider: PROVIDER, provider_ien: 9001, locked: false)
        # `at: nil` is a row whose FileMan date is blank: the gem yields a nil datetime.
        fileman = at && format("%<ymd>s.%<hm>s", ymd: "#{at.year - 1700}#{at.strftime('%m%d')}", hm: at.strftime("%H%M"))
        { visit_string: "40;#{fileman};A;#{ien}", location: clinic, category: "AMBULATORY",
          datetime: at, locked: locked, provider_ien: provider_ien, provider: provider }
      end

      def seed_visits(dfn, rows)
        RpmsRpc.client.seed_keyed_collection(:encounter_visit_list, dfn.to_s, rows)
      end

      # A wall-clock time on a day relative to Date.current, kept to office
      # hours so no time zone can move it onto a neighbouring date.
      def today_at(hour, minute = 0, days_ago: 0)
        day = Date.current - days_ago
        Time.zone.local(day.year, day.month, day.day, hour, minute)
      end

      def visit_radios = css_select("input[type=radio][name=encounter_ien]")
      def offered_visit_iens = visit_radios.map { |radio| radio["value"] }
      def checked_visit_iens = visit_radios.select { |radio| radio.key?("checked") }.map { |radio| radio["value"] }

      # The visible text of the <label for> bound to a visit's radio.
      def visit_label_text(ien)
        radio = visit_radios.find { |candidate| candidate["value"] == ien.to_s }
        assert radio, "expected a radio name=encounter_ien value=#{ien}; offered: #{offered_visit_iens.inspect}"
        assert radio["id"].present?, "the visit radio needs an id for its label to bind to"
        label = css_select("label[for='#{radio['id']}']").first
        assert label, "expected a <label for=#{radio['id'].inspect}> for visit #{ien}"
        label.text.squish
      end

      # The clinician never types an internal record number: nothing named
      # encounter_ien is a typed field (a text input, a number input, an input
      # with no type, a textarea), in any state of the form.
      def assert_no_typed_visit_field
        assert_select "input[name=encounter_ien]:not([type=radio]):not([type=hidden])", count: 0
        assert_select "textarea[name=encounter_ien]", count: 0
      end

      def assert_alert(pattern)
        texts = css_select("[role=alert]").map { |node| node.text.squish }
        assert texts.any? { |text| text.match?(pattern) },
               "expected a role=alert region matching #{pattern.inspect}; alerts were: #{texts.inspect}"
      end

      def assert_no_alert(pattern)
        texts = css_select("[role=alert]").map { |node| node.text.squish }
        assert texts.none? { |text| text.match?(pattern) },
               "expected no role=alert region matching #{pattern.inspect}; alerts were: #{texts.inspect}"
      end

      # A day shown in any of the usual clinical renderings.
      def assert_shows_date(text, time)
        formats = [ "%b %-d, %Y", "%B %-d, %Y", "%b %d, %Y", "%Y-%m-%d", "%m/%d/%Y", "%-m/%-d/%Y", "%-d %b %Y", "%d %b %Y" ]
        assert formats.any? { |fmt| text.include?(time.strftime(fmt)) },
               "expected #{text.inspect} to show the date #{time.to_date.iso8601}"
      end

      # 24-hour or 12-hour clock.
      def assert_shows_time(text, time)
        assert [ time.strftime("%H:%M"), time.strftime("%-l:%M") ].any? { |shown| text.include?(shown) },
               "expected #{text.inspect} to show the time #{time.strftime('%H:%M')}"
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
        }.merge(csrf_param).merge(extra)
      end

      # -- The form ------------------------------------------------------------

      test "GET new renders every PHQ-9 item as a labelled radio group" do
        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }, headers: auth_headers

        assert_response :ok
        assert_select "fieldset.screening-item", 9
        assert_select "legend", /Little interest or pleasure in doing things/
        # Four choices per item, each with an explicit label bound to its input.
        # (Counted by name: the visit choices of #1003 are radios too.)
        assert_select "input[type=radio][name^=answers]", 36
        PHQ9.link_ids.each do |link_id|
          assert_select "input[type=radio][name=?]", "answers[#{link_id}]", 4
          assert_select "label[for=?]", "answer-#{link_id}-0"
        end
      end

      test "GET new renders the seven GAD-7 items" do
        get "#{BASE}/new", params: { instrument: "gad-7" }, headers: auth_headers

        assert_response :ok
        assert_select "fieldset.screening-item", 7
        assert_select "input[type=radio][name^=answers]", 28
      end

      test "the form carries no JavaScript" do
        get "#{BASE}/new", params: { instrument: "phq-9" }, headers: auth_headers

        # The only script allowed is the consent re-lock listener (#793), which the form does not depend on.
        assert_select "script:not([data-consent-kiosk-listener])", count: 0
        assert_no_match(/onclick=/i, response.body)
        assert_no_match(/\son[a-z]+=/i, response.body)
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
        reset! # a fresh browser: no session, no credential

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :unauthorized
        assert_no_match(/Little interest or pleasure/, response.body)
      end

      test "a browser token presented from a header is refused (#486 binding)" do
        token = token_for
        reset!

        get "#{BASE}/new", params: { instrument: "phq-9" }, headers: auth_headers(token)

        assert_response :unauthorized
      end

      test "a revoked token closes the surface" do
        @token.update!(revoked_at: Time.current)

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :unauthorized
      end

      test "an expired token closes the surface" do
        @token.update!(created_at: 2.days.ago, expires_in: 60)

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :unauthorized
      end

      test "a token with no QuestionnaireResponse scope cannot read the answers" do
        submit
        id = ScreeningResponse.last.id
        sign_in(scopes: "user/Patient.read") # a keyless provider's session

        get "#{BASE}/#{id}"

        assert_response :forbidden
        assert_no_match(/#{SELF_HARM_ITEM_TEXT}/i, response.body)
      end

      test "an empty-scope token — a keyless provider — reads nothing" do
        submit
        id = ScreeningResponse.last.id
        sign_in(scopes: "")

        get "#{BASE}/#{id}"

        assert_response :forbidden
      end

      test "a read scope does not authorize recording a screening" do
        sign_in(scopes: "user/QuestionnaireResponse.read")

        assert_no_difference -> { ScreeningResponse.count } do
          post BASE, params: {
            instrument: PHQ9.key, encounter_ien: VISIT,
            answers: complete_without_safety_flag(PHQ9)
          }.merge(csrf_param)
        end
        assert_response :forbidden
      end

      test "a patient-scoped token bound to another patient cannot read this one" do
        submit
        id = ScreeningResponse.last.id
        other = patient_token(dfn: "2", scopes: "patient/QuestionnaireResponse.read")

        get "#{BASE}/#{id}", headers: auth_headers(other)

        assert_response :forbidden
      end

      # `resource_owner_id` is a PATIENT dfn on a patient-scoped token and a
      # clinician DUZ on a sign-on token. Reading it blind attributes the
      # self-harm risk assessment — the record, the acknowledgement trace and
      # the audit log — to the patient who disclosed it.
      test "a patient-scoped token cannot record a screening at all" do
        patient = patient_token(dfn: "1")

        assert_no_difference -> { ScreeningResponse.count } do
          post BASE, params: {
            instrument: PHQ9.key, encounter_ien: VISIT,
            answers: complete_without_safety_flag(PHQ9)
          }.merge(csrf_param), headers: auth_headers(patient)
        end

        assert_response :forbidden
      end

      test "a patient-scoped token is never audited as a practitioner" do
        patient = patient_token(dfn: "1")
        AuditEvent.delete_all

        get BASE, headers: auth_headers(patient)

        event = AuditEvent.recent.first
        assert_not_nil event
        assert_not_equal "Practitioner", event.agent_who_type,
                         "a patient credential must not be recorded as the clinician"
        assert_not_equal "1", event.agent_who_identifier
      end

      # `clinician_credential?` and `current_duz` were different predicates, so
      # a token on an app NAMED like the sign-on app but carrying no
      # resource_owner_id — a client_credentials grant — passed the credential
      # check and then recorded a screening authored by nobody.
      #
      # Under #486's binding this is refused even earlier: a browser-shaped
      # token in a header is not a valid presentation at all (401), and via
      # the session the empty DUZ fails the session⇄token binding. Either
      # way, no screening is recorded — the 403 clinician-credential gate
      # remains as defense in depth behind it.
      test "a sign-on-shaped token with no DUZ cannot record a screening" do
        anonymous = token_for(duz: nil)

        assert_no_difference -> { ScreeningResponse.count } do
          post BASE, params: {
            instrument: PHQ9.key, encounter_ien: VISIT,
            answers: complete_without_safety_flag(PHQ9)
          }.merge(csrf_param), headers: auth_headers(anonymous)
        end

        assert_response :unauthorized
      end

      # F6: a backend credential has no human behind it, so it cannot author a
      # clinician administration — the row would name nobody.
      test "a system token cannot record an unauthored clinician administration" do
        assert_no_difference -> { ScreeningResponse.count } do
          post BASE, params: {
            instrument: PHQ9.key, encounter_ien: VISIT,
            answers: complete_without_safety_flag(PHQ9)
          }.merge(csrf_param), headers: auth_headers(system_token)
        end

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


      def stub_egress_filter(implementation)
        filter = Part2EgressFilter.singleton_class
        original = filter.instance_method(:call)
        filter.define_method(:call, &implementation)
        yield
      ensure
        filter.define_method(:call, original)
      end

      test "the flash notice on create does not contain the score or severity band when filtered" do
        stub_egress_filter(->(payload) {
          if payload.is_a?(Hash)
            payload = payload.deep_dup.deep_stringify_keys
            if payload["resourceType"] == "Bundle"
              payload["entry"].reject! { |e| e.dig("resource", "resourceType") == "Observation" }
            end
          end
          payload
        }) do
          submit(answers: answers(PHQ9, [ 3, 3, 3, 3, 3, 3, 3, 3, 0 ]))
          follow_redirect_authorized!
        end

        assert_response :ok
        # Scoped: the whole page also carries a CSRF token, which can contain "24".
        [ ".flash-notice", ".screening-score", "tfoot" ].each do |selector|
          css_select(selector).each do |node|
            assert_no_match(/\b24\b/, node.text, "#{selector} shows the withheld total")
            assert_no_match(/severe/i, node.text, "#{selector} shows the withheld band")
          end
        end
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
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-errors", /Visit required/
      end

      test "a submission missing both the visit and answers names both" do
        missing = [ PHQ9.items[2].link_id, PHQ9.items[7].link_id ]
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1).except(*missing) }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_select ".screening-errors", /Visit required/
        assert_select ".screening-errors", /not scored/i
        assert_select ".screening-errors[role=alert] li", 2
      end

      # -- Idempotency -----------------------------------------------------------

      test "the form carries a submission token" do
        get "#{BASE}/new", params: { instrument: "phq-9" }, headers: auth_headers

        assert_select "input[type=hidden][name=submission_token]" do |inputs|
          assert_predicate inputs.first["value"].to_s, :present?
        end
      end

      test "the same form submitted twice does not create a second administration" do
        token = SecureRandom.uuid
        submit(submission_token: token)
        first_id = ScreeningResponse.last.id

        assert_no_difference -> { ScreeningResponse.count } do
          submit(submission_token: token)
        end
        assert_redirected_to "#{BASE}/#{first_id}"
      end

      # A collapse is not a recording. Telling the clinician "PHQ-9 recorded —
      # score N" for a submission that wrote nothing is how a discarded
      # administration goes unnoticed.
      test "a replayed submission is reported as already recorded, not as recorded" do
        token = SecureRandom.uuid
        submit(submission_token: token)
        submit(submission_token: token)
        follow_redirect_authorized!

        assert_match(/already recorded/i, response.body)
        assert_no_match(/PHQ-9 recorded —/i, response.body)
      end

      # Two separately rendered forms are two submissions, even with identical
      # answers: an 08:00 screen and a 16:00 re-screen are two administrations.
      test "a second form with identical answers is its own administration" do
        submit(submission_token: SecureRandom.uuid)

        assert_difference -> { ScreeningResponse.count }, 1 do
          submit(submission_token: SecureRandom.uuid)
        end
      end

      test "a form resubmitted with changed answers is refused, not silently collapsed" do
        token = SecureRandom.uuid
        submit(submission_token: token)

        assert_no_difference -> { ScreeningResponse.count } do
          submit(answers: all_answered(PHQ9, 0), submission_token: token)
        end

        assert_response :unprocessable_entity
        assert_match(/already been submitted/i, response.body)
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
        # The only script allowed is the consent re-lock listener (#793), which the form does not depend on.
        assert_select "script:not([data-consent-kiosk-listener])", count: 0
        assert_no_match(/\son[a-z]+=/i, response.body)
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
        }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-safety[role=alert]"
      end

      test "a GAD-7 with every item maxed needs no safety acknowledgement" do
        submit(instrument: GAD7, answers: all_answered(GAD7, 3))

        assert_equal 21, ScreeningResponse.last.total_score
      end

      # -- Audit (the policy every FHIR controller and the chart follow) --------

      test "reading a screening result is audited against the clinician and that screening" do
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
        # The RESOURCE that was read, not the patient whose route it hung off.
        assert_equal id.to_s, event.entity_identifier
      end

      test "listing a patient's screenings is audited against the patient" do
        assert_difference -> { AuditEvent.count }, 1 do
          get BASE, headers: auth_headers
        end

        event = AuditEvent.recent.first
        assert_equal "Patient", event.entity_type
        assert_equal DFN_PARAM, event.entity_identifier
      end

      test "recording a screening is audited as a create" do
        assert_difference -> { AuditEvent.count }, 1 do
          submit
        end

        assert_equal "C", AuditEvent.recent.first.action
      end

      # A successful write REDIRECTS, and 302 fell outside the success range —
      # so every recorded PHQ-9, self-harm-flagged ones included, was logged
      # `outcome: "8"`: *serious failure* in the FHIR value set, and
      # indistinguishable from a genuine one, since the fail-closed path emits
      # "8" too. Asserting the action and not the outcome is what hid it.
      test "a successful screening create is audited as a success, not a failure" do
        submit

        assert_response :redirect
        event = AuditEvent.recent.first
        assert_equal "C", event.action
        assert_equal "0", event.outcome, "a recorded screening is not a serious failure"
        assert_predicate event, :success?
      end

      # The audit entity is a REFERENCE — `<type>/<identifier>` — so the two
      # halves have to agree. Preferring the route's patient dfn emitted
      # `QuestionnaireResponse/1` for screening 100: syntactically valid,
      # resolvable, and pointing at a DIFFERENT patient's screening. Worse
      # than a null, and invisible to a test that asserts only the type.
      def assert_audit_reference(expected)
        event = AuditEvent.recent.first
        assert_not_nil event
        assert_equal expected, "#{event.entity_type}/#{event.entity_identifier}"
        assert_equal expected, event.to_fhir[:entity].first.dig(:what, :reference)
      end

      # The reviewer's reproduction, pinned with its own numbers: screening 100
      # on patient 1. With incidental ids a regression could hide behind
      # `record.id` happening to be small; here the two are unmistakable, and
      # the pre-fix value ("QuestionnaireResponse/1") is asserted against
      # directly.
      test "screening 100 on patient 1 audits as QuestionnaireResponse/100" do
        ScreeningResponse.connection.execute(
          "ALTER SEQUENCE lakeraven_ehr_screening_responses_id_seq RESTART WITH 100"
        )
        AuditEvent.delete_all

        submit
        record = ScreeningResponse.last
        assert_equal 100, record.id

        create_reference = "#{AuditEvent.recent.first.entity_type}/" \
                           "#{AuditEvent.recent.first.entity_identifier}"
        assert_equal "QuestionnaireResponse/100", create_reference
        assert_not_equal "QuestionnaireResponse/#{DFN_PARAM}", create_reference

        AuditEvent.delete_all
        get "#{BASE}/100", headers: auth_headers

        assert_response :ok
        assert_audit_reference("QuestionnaireResponse/100")
      end

      # The guard below is the point of this test: if the audit named the DFN
      # instead of the screening, an id that happened to equal DFN_PARAM would
      # hide it. So GUARANTEE the two differ rather than asserting and hoping —
      # the sequence is shared across the suite and Minitest randomises order,
      # so whether this row lands on id 1 (== DFN_PARAM) varied per seed and the
      # guard failed the run outright roughly whenever it did. Same pinning
      # idiom as the screening-100 reproduction above.
      test "the create audit names the screening that was created" do
        ScreeningResponse.connection.execute(
          "ALTER SEQUENCE lakeraven_ehr_screening_responses_id_seq RESTART WITH 500"
        )

        submit
        record = ScreeningResponse.last

        assert_equal 500, record.id, "the sequence pin above should decide this id"
        assert_not_equal DFN_PARAM, record.id.to_s,
                         "guard: with id == dfn this test would pass vacuously"
        assert_audit_reference("QuestionnaireResponse/#{record.id}")
      end

      test "the read audit names the screening that was read" do
        submit
        record = ScreeningResponse.last
        AuditEvent.delete_all

        get "#{BASE}/#{record.id}", headers: auth_headers

        assert_response :ok
        assert_audit_reference("QuestionnaireResponse/#{record.id}")
      end

      # Actions with no single resource of their own are audited against the
      # PATIENT — the pattern the chart already uses for a patient-centric
      # aggregate — never as a QuestionnaireResponse carrying a patient id.
      test "the history audit names the patient, not a screening" do
        submit
        AuditEvent.delete_all

        get BASE, headers: auth_headers

        assert_audit_reference("Patient/#{DFN_PARAM}")
      end

      test "a refused create names the patient rather than a screening that does not exist" do
        AuditEvent.delete_all

        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_audit_reference("Patient/#{DFN_PARAM}")
      end

      test "a successful patient-context open is audited as a success" do
        reset!
        sign_in
        open_patient(1)

        assert_response :redirect
        event = AuditEvent.recent.first
        assert_equal "E", event.action
        assert_equal "0", event.outcome
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

      # The write path is the one that matters here: a read that is not audited
      # costs a log line, but an unaudited WRITE leaves a durable clinical
      # record — a self-harm-flagged one — that the audit log has never heard
      # of, while the clinician is told the opposite.
      test "no screening is written when the access cannot be recorded" do
        AuditEvent.delete_all # the patient-context open in setup left one

        assert_no_difference -> { ScreeningResponse.count } do
          with_broken_audit do
            submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 3),
                   safety_acknowledged: "1")
          end
        end

        assert_response :service_unavailable
        assert_equal 0, AuditEvent.count
      end

      # The flash rides in the SESSION COOKIE, not the response body, so a
      # refused write can leak a score onto the clinician's next page.
      #
      # Asserting that on a page which never renders a flash would be vacuous —
      # `show` is the only one that does, so the leak is chased to where it
      # would actually surface, and the carrier itself is asserted in its
      # DECODED form rather than as cookie bytes.
      test "the score does not survive a refused write in the flash" do
        submit(submission_token: SecureRandom.uuid)
        landing_page = "#{BASE}/#{ScreeningResponse.last.id}"
        follow_redirect_authorized! # consume this submission's own notice
        assert_select ".flash-notice", text: /recorded/i # guard: show renders the flash (I1: it carries no score)

        with_broken_audit do
          submit(answers: answers(PHQ9, [ 3, 3, 3, 3, 3, 3, 3, 3, 0 ]),
                 submission_token: SecureRandom.uuid)
        end

        assert_response :service_unavailable
        assert_nil flash[:notice], "a refused write must leave nothing in the flash"

        get landing_page, headers: auth_headers

        assert_response :ok
        assert_no_match(/recorded — score 24/i, response.body)
        assert_no_match(/Severe/, response.body)
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

      # -- Fail closed AND SAY WHY ---------------------------------------------
      #
      # A 422 that re-renders the form with the answers still selected and no
      # statement that anything was refused reads as "the page reloaded".

      test "a refusal caused by a corrupt prior row says so on the form" do
        token = SecureRandom.uuid
        submit(submission_token: token)
        ScreeningResponse.last.update_column(:total_score, 999)

        submit(submission_token: token)

        assert_response :unprocessable_entity
        assert_select ".screening-errors[role=alert]", /could not be recorded/i
      end

      test "a refusal caused by a storage failure says so on the form" do
        with_failing(ScreeningResponse, :create!,
                     ->(*) { raise ActiveRecord::StatementInvalid, "disk full" }) do
          submit
        end

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_select ".screening-errors[role=alert]", /could not be recorded/i
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

      # -- Visit picker (#1003) --------------------------------------------------
      #
      # The form used to ask for a "Visit (encounter) number" in a free-text
      # field, and nothing in the browser shows that number. It now offers the
      # patient's OPEN visits — read from BEHOENCX VISITLST, the same list the
      # chart's Encounter read uses — and create accepts only one of them.

      test "GET new offers each open visit as a labelled radio showing when, where and with whom" do
        earlier = today_at(14, 45, days_ago: 3)
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090050", at: earlier, clinic: "Cedar Hollow Primary Care", provider: "TESTPROVIDER,BRAVO")
        ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal [ VISIT, "2090050" ].sort, offered_visit_iens.sort

        today_label = visit_label_text(VISIT)
        assert_includes today_label, CLINIC
        assert_includes today_label, PROVIDER
        assert_shows_time today_label, today_at(9, 30)

        earlier_label = visit_label_text("2090050")
        assert_includes earlier_label, "Cedar Hollow Primary Care"
        assert_includes earlier_label, "TESTPROVIDER,BRAVO"
        assert_shows_date earlier_label, earlier
        assert_shows_time earlier_label, earlier
      end

      test "the visit IEN is the radio's value and never visible text" do
        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_not_includes visit_label_text(VISIT), VISIT
        assert_not_includes css_select("form.screening-form").text, VISIT
      end

      test "a locked visit is not offered" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090040", at: today_at(11, 0), clinic: "Cedar Hollow Primary Care", locked: true)
        ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_select "input[name=encounter_ien][value=?]", "2090040", count: 0
        assert_no_match(/Cedar Hollow Primary Care/, response.body)
      end

      test "only this patient's visits are offered" do
        seed_visits(OTHER_DFN, [ visit_row(OTHER_PATIENT_VISIT, at: today_at(10, 0), clinic: "Cedar Hollow Primary Care") ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
      end

      # Today's visits first (the one just checked in), newest first within
      # today; then everything else, newest first. Seeded out of order, with a
      # visit dated after today, so neither the seed order nor a plain
      # newest-first sort satisfies it.
      test "today's visits come first, then the rest, newest first" do
        seed_visits(DFN_PARAM, [
          visit_row("3001", at: today_at(10, 0, days_ago: 1)),
          visit_row("3002", at: today_at(8, 15)),
          visit_row("3003", at: today_at(9, 0, days_ago: -1)),
          visit_row("3004", at: today_at(15, 20)),
          visit_row("3005", at: today_at(13, 0, days_ago: 30))
        ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal %w[3004 3002 3003 3001 3005], offered_visit_iens
      end

      test "the form has no typed visit number" do
        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_no_typed_visit_field
        assert_no_match(/Visit \(encounter\) number/i, response.body)
      end

      test "a re-rendered form has no typed visit number either" do
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_no_typed_visit_field
      end

      test "a visit carried in from the context it was opened from is preselected" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090050", at: today_at(14, 45, days_ago: 3))
        ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: "2090050" }

        assert_response :ok
        assert_equal [ "2090050" ], checked_visit_iens
      end

      test "with no visit in the context nothing is preselected" do
        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_empty checked_visit_iens
      end

      test "a visit in the context that is not one of the patient's open visits is neither preselected nor offered" do
        seed_visits(OTHER_DFN, [ visit_row(OTHER_PATIENT_VISIT, at: today_at(10, 0)) ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: OTHER_PATIENT_VISIT }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_empty checked_visit_iens
        assert_select "input[name=encounter_ien][value=?]", OTHER_PATIENT_VISIT, count: 0
        assert_no_match(/#{OTHER_PATIENT_VISIT}/, response.body)
      end

      test "a locked visit in the context is neither preselected nor offered" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090040", at: today_at(11, 0), locked: true)
        ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: "2090040" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_empty checked_visit_iens
        assert_select "input[name=encounter_ien][value=?]", "2090040", count: 0
      end

      test "a patient with no open visit is told to check the patient in first" do
        seed_visits(DFN_PARAM, [ visit_row("2090040", at: today_at(11, 0), locked: true) ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_alert(/No open visit/i)
        assert_alert(/No open visit.*check/im)
        assert_empty offered_visit_iens
        assert_no_typed_visit_field
      end

      test "a patient with no visits at all is told there is no open visit" do
        seed_visits(DFN_PARAM, [])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_alert(/No open visit/i)
        assert_empty offered_visit_iens
        assert_no_typed_visit_field
      end

      # Fail closed AND SAY WHY: a list that could not be read is not an
      # empty list, and it is not an invitation to type a number instead.
      test "without an Encounter read scope the form says the visits could not be read and offers none" do
        sign_in(scopes: SCREENING_ONLY_SCOPES)
        open_patient(1)

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }

        assert_response :ok
        assert_alert(/visits could not be read/i)
        assert_empty offered_visit_iens
        assert_select "input[name=encounter_ien][value=?]", VISIT, count: 0
        assert_no_typed_visit_field
        assert_select "fieldset.screening-item", 9
      end

      test "without an Encounter read scope the visit list is not read at all" do
        sign_in(scopes: SCREENING_ONLY_SCOPES)
        open_patient(1)
        reads = 0

        with_failing(EncounterGateway, :visits, ->(*) { reads += 1; [] }) do
          get "#{BASE}/new", params: { instrument: "phq-9" }
        end

        assert_response :ok
        assert_equal 0, reads, "a credential that may not read Encounter must not cause a visit read"
        assert_alert(/visits could not be read/i)
      end

      [ [ "RpmsRpc::Error", -> { raise RpmsRpc::Error, "broker down" } ],
        [ "IOError", -> { raise IOError, "socket closed" } ] ].each do |name, failure|
        test "a visit read that raises #{name} renders the form saying the visits could not be read" do
          with_failing(EncounterGateway, :visits, ->(*) { failure.call }) do
            get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }
          end

          assert_response :ok
          assert_alert(/visits could not be read/i)
          assert_empty offered_visit_iens
          assert_select "input[name=encounter_ien][value=?]", VISIT, count: 0
          assert_no_typed_visit_field
          assert_no_match(/broker down|socket closed/, response.body)
        end

        test "a submission while the visit read raises #{name} is refused and says the visits could not be read" do
          with_failing(EncounterGateway, :visits, ->(*) { failure.call }) do
            submit
          end

          assert_response :unprocessable_entity
          assert_equal 0, ScreeningResponse.count
          assert_alert(/visits could not be read/i)
          assert_no_typed_visit_field
        end
      end

      # The acceptance path: check in, open the chart, start a PHQ-9, save it
      # against that visit — choosing it, never typing it.
      test "the visit chosen from the form is the visit the screening is saved against" do
        seed_visits(DFN_PARAM, [
          visit_row("2090050", at: today_at(14, 45, days_ago: 3), clinic: "Cedar Hollow Primary Care"),
          visit_row(VISIT, at: today_at(9, 30))
        ])
        get "#{BASE}/new", params: { instrument: "phq-9" }
        assert_response :ok
        chosen = offered_visit_iens.find { |ien| visit_label_text(ien).include?(CLINIC) }
        assert_equal VISIT, chosen, "expected today's #{CLINIC} visit among the choices"

        submit(encounter_ien: chosen)

        assert_response :redirect
        assert_equal 1, ScreeningResponse.count
        assert_equal VISIT, ScreeningResponse.last.encounter_ien.to_s
      end

      test "a visit that is not in this patient's visit list is refused" do
        seed_visits(OTHER_DFN, [ visit_row(OTHER_PATIENT_VISIT, at: today_at(10, 0)) ])

        submit(encounter_ien: OTHER_PATIENT_VISIT)

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
        assert_select "fieldset.screening-item", 9
        assert_empty checked_visit_iens
        assert_select "input[name=encounter_ien][value=?]", OTHER_PATIENT_VISIT, count: 0
      end

      test "a visit number nobody was offered is refused" do
        submit(encounter_ien: "1")

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
      end

      test "a locked visit is refused" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090040", at: today_at(11, 0), locked: true)
        ])

        submit(encounter_ien: "2090040")

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
      end

      # The list is read when the form is SUBMITTED, not remembered from when
      # it was rendered: a visit locked in between is no longer a choice.
      test "a visit that was open when the form rendered and is locked at submission is refused" do
        get "#{BASE}/new", params: { instrument: "phq-9" }
        assert_equal [ VISIT ], offered_visit_iens
        seed_visits(DFN_PARAM, [ visit_row(VISIT, at: today_at(9, 30), locked: true) ])

        submit

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
      end

      test "a submission without an Encounter read scope is refused and says the visits could not be read" do
        sign_in(scopes: SCREENING_ONLY_SCOPES)
        open_patient(1)

        submit

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/visits could not be read/i)
        assert_no_typed_visit_field
      end

      test "a refused visit does not hide the unanswered items" do
        missing = [ PHQ9.items[2].link_id ]

        submit(encounter_ien: "1", answers: complete_without_safety_flag(PHQ9).except(*missing))

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
        assert_select ".screening-errors", /not scored/i
      end

      test "a submission with no visit is told to choose one, not to enter a number" do
        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/Visit required/)
        assert_alert(/Visit required.*choose/im)
        assert_no_match(/Enter the visit number/i, response.body)
        assert_equal [ VISIT ], offered_visit_iens
      end

      test "the chosen visit survives a re-render for unanswered items" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090050", at: today_at(14, 45, days_ago: 3))
        ])

        submit(encounter_ien: "2090050", answers: { PHQ9.items[0].link_id => 3 })

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_equal [ "2090050" ], checked_visit_iens
        assert_select "input[type=radio][id=?][checked]", "answer-#{PHQ9.items[0].link_id}-3"
      end

      test "the chosen visit survives the safety prompt" do
        submit(answers: all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2))

        assert_response :unprocessable_entity
        assert_select ".screening-safety[role=alert]"
        assert_equal [ VISIT ], checked_visit_iens
      end

      test "the visit choices add no JavaScript" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090050", at: today_at(14, 45, days_ago: 3))
        ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }

        assert_equal 2, visit_radios.length
        assert_select "script:not([data-consent-kiosk-listener])", count: 0
        assert_no_match(/\son[a-z]+=/i, response.body)
      end

      # -- Visit picker, amendment 1 (#1003 review) ------------------------------

      # 1. Only `locked == false` is open. The gem maps an empty or absent
      # LOCKED piece to nil: an unknown lock state is not an open visit.
      test "a visit whose lock state is unknown is not offered" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090041", at: today_at(11, 0), clinic: "Cedar Hollow Primary Care", locked: nil)
        ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: "2090041" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_empty checked_visit_iens
        assert_select "input[name=encounter_ien][value=?]", "2090041", count: 0
        assert_no_match(/Cedar Hollow Primary Care/, response.body)
      end

      test "a patient whose only visit has an unknown lock state has no open visit" do
        seed_visits(DFN_PARAM, [ visit_row(VISIT, at: today_at(9, 30), locked: nil) ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_empty offered_visit_iens
        assert_alert(/No open visit/i)
      end

      test "a visit whose lock state is unknown is refused" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090041", at: today_at(11, 0), locked: nil)
        ])

        submit(encounter_ien: "2090041")

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
      end

      # 2. The gem yields a nil datetime for a blank or unparseable FileMan
      # date. Such a row cannot be dated — so cannot be shown as today's or
      # any day's visit — and it must not take the form down with it.
      test "a visit with no date, alone, does not break the form and is not offered" do
        seed_visits(DFN_PARAM, [ visit_row("2090042", at: nil) ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: "2090042" }

        assert_response :ok
        assert_empty offered_visit_iens
        assert_alert(/No open visit|visits could not be read/i)
        assert_select "fieldset.screening-item", 9
      end

      test "a visit with no date is left out and the dated visits are still offered in order" do
        seed_visits(DFN_PARAM, [
          visit_row("3001", at: today_at(10, 0, days_ago: 1)),
          visit_row("2090042", at: nil, clinic: "Cedar Hollow Primary Care"),
          visit_row("3002", at: today_at(8, 15)),
          visit_row("3004", at: today_at(15, 20))
        ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal %w[3004 3002 3001], offered_visit_iens
        assert_no_match(/Cedar Hollow Primary Care/, response.body)
      end

      test "a submission naming a visit with no date, alone, is refused without an error" do
        seed_visits(DFN_PARAM, [ visit_row("2090042", at: nil) ])

        submit(encounter_ien: "2090042")

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_empty offered_visit_iens
      end

      test "a submission naming a visit with no date is refused" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090042", at: nil)
        ])

        submit(encounter_ien: "2090042")

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/not one of this patient['’]s open visits/i)
        assert_equal [ VISIT ], offered_visit_iens
      end

      test "a dated visit still saves when another row has no date" do
        seed_visits(DFN_PARAM, [
          visit_row("2090042", at: nil),
          visit_row(VISIT, at: today_at(9, 30))
        ])

        submit

        assert_response :redirect
        assert_equal 1, ScreeningResponse.count
        assert_equal VISIT, ScreeningResponse.last.encounter_ien.to_s
      end

      # 3. One radio per visit: a repeated row must not repeat the choice, or
      # the element ids its label binds to.
      test "two rows for the same visit render one radio" do
        seed_visits(DFN_PARAM, [
          visit_row(VISIT, at: today_at(9, 30)),
          visit_row("2090050", at: today_at(14, 45, days_ago: 3)),
          visit_row(VISIT, at: today_at(9, 30))
        ])

        get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }

        assert_response :ok
        assert_equal [ VISIT, "2090050" ], offered_visit_iens
        assert_equal [ VISIT ], checked_visit_iens
        ids = css_select("[id]").map { |node| node["id"] }
        assert_empty ids.tally.select { |_id, count| count > 1 }.keys, "duplicate element ids on the page"
      end

      # 4. A visit with no clinic or no provider on file is still a visit the
      # clinician may need; the label says what is missing instead of trailing
      # off into an empty separator.
      test "a visit with no clinic or provider is offered and says what is not recorded" do
        seed_visits(DFN_PARAM, [
          visit_row("3101", at: today_at(15, 0), clinic: nil),
          visit_row("3102", at: today_at(14, 0), provider: nil, provider_ien: nil),
          visit_row("3103", at: today_at(13, 0), clinic: nil, provider: nil, provider_ien: nil)
        ])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal %w[3101 3102 3103], offered_visit_iens

        no_clinic = visit_label_text("3101")
        assert_match(/clinic not recorded/i, no_clinic)
        assert_includes no_clinic, PROVIDER
        assert_no_match(/provider not recorded/i, no_clinic)

        no_provider = visit_label_text("3102")
        assert_match(/provider not recorded/i, no_provider)
        assert_includes no_provider, CLINIC
        assert_no_match(/clinic not recorded/i, no_provider)

        neither = visit_label_text("3103")
        assert_match(/clinic not recorded/i, neither)
        assert_match(/provider not recorded/i, neither)

        { no_clinic => 15, no_provider => 14, neither => 13 }.each do |label, hour|
          assert_shows_time label, today_at(hour, 0)
          assert_no_match(/[·•|]\s*(?:[·•|]|\z)/, label, "the label has an empty separator")
        end
      end

      # 5. Listing a patient's visits is a FHIR search: SMART v2 `s` (a v1
      # `.read` carries it). `r` alone reads one Encounter by id and does not
      # list them.
      test "an Encounter read-by-id scope without search does not list the visits" do
        sign_in(scopes: "#{SCREENING_ONLY_SCOPES} user/Encounter.r")
        open_patient(1)
        reads = 0
        rows = EncounterGateway.visits(DFN_PARAM)

        with_failing(EncounterGateway, :visits, ->(*) { reads += 1; rows }) do
          get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }
        end

        assert_response :ok
        assert_alert(/visits could not be read/i)
        assert_empty offered_visit_iens
        assert_equal 0, reads, "a credential that may not search Encounter must not cause a visit read"
        assert_no_typed_visit_field
      end

      test "a submission with an Encounter read-by-id scope without search is refused" do
        sign_in(scopes: "#{SCREENING_ONLY_SCOPES} user/Encounter.r")
        open_patient(1)

        submit

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/visits could not be read/i)
      end

      test "an Encounter search scope alone lists the visits and saves against one" do
        sign_in(scopes: "#{SCREENING_ONLY_SCOPES} user/Encounter.s")
        open_patient(1)

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_equal [ VISIT ], offered_visit_iens
        assert_includes visit_label_text(VISIT), CLINIC

        submit

        assert_response :redirect
        assert_equal 1, ScreeningResponse.count
        assert_equal VISIT, ScreeningResponse.last.encounter_ien.to_s
      end

      # 6. Visit times from rpms-rpc are plain `Time.new(...)` in the server's
      # process zone — the clinic's wall clock (WallClock). "Today" is therefore
      # the process-local date, not Date.current in Time.zone. Deterministic on
      # any host: time is frozen at process-local noon, and Time.zone is set to
      # whichever zone is on a different calendar date at that instant (one
      # always exists: zones span UTC-12 to UTC+13). The other visit is dated
      # on that zone's date, so reading "today" from Time.zone puts it first.
      test "today is the clinic's wall-clock date, not the date in Time.zone" do
        now = Time.now
        local_noon = Time.new(now.year, now.month, now.day, 12, 0, 0)
        local_date = Date.new(now.year, now.month, now.day)
        zone = ActiveSupport::TimeZone.all.find { |candidate| local_noon.in_time_zone(candidate).to_date != local_date }
        assert zone, "no zone is on another date at process-local noon"
        zone_date = local_noon.in_time_zone(zone).to_date

        travel_to(local_noon) do
          Time.use_zone(zone) do
            assert_not_equal local_date, Date.current, "the fixture needs Time.zone on another date"
            sign_in # the setup credential was minted at the real time
            open_patient(1)
            seed_visits(DFN_PARAM, [
              visit_row("4002", at: Time.new(zone_date.year, zone_date.month, zone_date.day, 9, 0, 0)),
              visit_row("4001", at: Time.new(local_date.year, local_date.month, local_date.day, 8, 0, 0))
            ])

            get "#{BASE}/new", params: { instrument: "phq-9" }
          end
        end

        assert_response :ok
        assert_equal %w[4001 4002], offered_visit_iens
      end

      # 7. "Choose the visit below" is only true when there is one to choose.
      test "a submission with no visit while the visits cannot be read is not told to choose one" do
        sign_in(scopes: SCREENING_ONLY_SCOPES)
        open_patient(1)

        post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/visits could not be read/i)
        assert_no_alert(/Visit required/i)
        assert_no_alert(/choose the visit/i)
      end

      test "a submission with no visit while the visit read raises is not told to choose one" do
        with_failing(EncounterGateway, :visits, ->(*) { raise RpmsRpc::Error, "broker down" }) do
          post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)
        end

        assert_response :unprocessable_entity
        assert_equal 0, ScreeningResponse.count
        assert_alert(/visits could not be read/i)
        assert_no_alert(/Visit required/i)
        assert_no_alert(/choose the visit/i)
      end

      [ [ "only a locked visit", ->(test) { [ test.visit_row("2090040", at: test.today_at(11, 0), locked: true) ] } ],
        [ "no visits at all", ->(_test) { [] } ] ].each do |name, rows|
        test "a submission with no visit for a patient with #{name} is not told to choose one" do
          seed_visits(DFN_PARAM, rows.call(self))

          post BASE, params: { instrument: "phq-9", answers: all_answered(PHQ9, 1) }.merge(csrf_param)

          assert_response :unprocessable_entity
          assert_equal 0, ScreeningResponse.count
          assert_alert(/No open visit/i)
          assert_no_alert(/Visit required/i)
          assert_no_alert(/choose the visit/i)
        end
      end

      # 8. An empty list is what a clinic with a check-in that has not reached
      # the visit file looks like too: the alert says what to do in that case
      # rather than asserting the patient was never checked in.
      test "the no-open-visit alert says what to do if the patient has already been checked in" do
        seed_visits(DFN_PARAM, [])

        get "#{BASE}/new", params: { instrument: "phq-9" }

        assert_response :ok
        assert_alert(/No open visit.*check/im)
        assert_alert(/No open visit.*already checked in/im)
        assert_alert(/No open visit.*already checked in.*reload/im)
        assert_alert(/No open visit.*already checked in.*report/im)
      end
    end
  end
end
