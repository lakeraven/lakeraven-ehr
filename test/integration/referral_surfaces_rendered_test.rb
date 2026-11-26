# frozen_string_literal: true

require "test_helper"
require_relative "../support/sud_words"
require_relative "../support/patient_banner_test_helper"

# #905 (slice of #522): the December build is MH/BH only, so the referral
# surfaces offer no structured SUD path. Proven on what the pages render:
# the whole response, layout and every partial and helper included, however
# a control was built, in every state the two pages have: rows, none, a failed
# or refused read, a refused window, every other capability's links and
# counts, and a patient open or searched for. RPMS is stood in for: the
# referrals, alerts and allergies are what rpms-rpc's reads answer, and the
# scheduling reads are answered at the wire.
class ReferralSurfacesRenderedTest < ActionDispatch::IntegrationTest
  include PatientBannerTestHelper

  TODAY = Date.new(2026, 11, 4)
  PENDING = "/lakeraven-ehr/referrals/pending"
  DASHBOARD = "/lakeraven-ehr/dashboard"

  # Two synthetic referrals, as RpmsRpc::Referral.pending returns them.
  SYNTHETIC_PENDING = [
    { ien: "1", date: Date.new(2026, 11, 1), patient_dfn: 990003, patient_name: "CHARLIE,JORDAN", facility: "<UNKNOWN>",
      status: "ACTIVE", chs_eligibility: "DIRECT ONLY", patient_dob: "06/03/1966" },
    { ien: "2", date: Date.new(2026, 11, 1), patient_dfn: 990003, patient_name: "CHARLIE,JORDAN", facility: "<UNKNOWN>",
      status: "APPROVED", chs_eligibility: "DIRECT ONLY", patient_dob: "06/03/1966" }
  ].freeze

  # Synthetic scheduling replies, in the shape the three BSDX reads answer
  # (test/integration/appointments_needing_action_test.rb): two clinics, and
  # two appointments today in the second, neither with anything recorded.
  SYNTHETIC_SCHEDULING = {
    "BSDX RESOURCES" =>
      "3\u0000I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^" \
      "T00030LETTER_TEXT^T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^" \
      "I00010MODIFY_SCHEDULE^I00010MODIFY_APPOINTMENTS\u001e" \
      "1^SYNTHETIC CLINIC A^0^15^6^^^^1^1^1^1\u001e2^SYNTHETIC CLINIC B^0^15^3^^^^1^1^1^1\u001e",
    "BSDX ALL APPOINTMENTS" => [
      "D00030START_TIME^D00030END_TIME^I00010PAT_ID^T00030RES_NAME",
      "NOV 04,2026 09:00^NOV 04,2026 09:15^990003^SYNTHETIC CLINIC B",
      "NOV 04,2026 16:00^NOV 04,2026 16:15^990003^SYNTHETIC CLINIC B"
    ],
    "BSDX CREATE APPT SCHEDULE" =>
      "5\u0000I00020APPOINTMENTID^D00030START_TIME^D00030END_TIME^D00030CHECKIN^D00030AUXTIME^I00020PATIENTID^" \
      "T00030PATIENTNAME^T00030RESOURCENAME^I00005NOSHOW^T00020HRN^I00005ACCESSTYPEID^I00005WALKIN^D00030CHECKOUT^" \
      "I00020VPROVIDER^T00020CANCELLED^T00250NOTE\u001e" \
      "71^NOV 04,2026 09:00^NOV 04,2026 09:15^^^990003^CHARLIE,JORDAN^SYNTHETIC CLINIC B^0^990003^0^0^^^0^\u001e" \
      "72^NOV 04,2026 16:00^NOV 04,2026 16:15^^^990003^CHARLIE,JORDAN^SYNTHETIC CLINIC B^0^990003^0^0^^^0^\u001e"
  }.freeze

  # Two synthetic alerts, as RpmsRpc::Notifications.inbox returns them
  # (test/integration/notifications_test.rb has the reply they are read from).
  SYNTHETIC_ALERTS = [
    { alert_id: "BEHOXQ,PROBE;4;3261104.075352", patient_dfn: nil, patient_name: nil, hrn: nil, location: nil,
      message: "Staff meeting moved to 3 PM.", delivered_at: Time.new(2026, 11, 4, 7, 53, 52), sender: "PROFILE,MANAGER",
      priority: :high, info_only: false, removable: false, type: "BEHOXQ" },
    { alert_id: "OR,3,19;.5;3261104.074742", patient_dfn: 3, patient_name: "CHARLIE,JORDAN", hrn: "990003", location: nil,
      message: "Unscheduled visit.", delivered_at: Time.new(2026, 11, 4, 7, 47, 42), sender: "PROFILE,MANAGER",
      priority: :moderate, info_only: true, removable: true, type: "OR.19" }
  ].freeze

  # The two allergies of the chart a state opens, as RpmsRpc::Allergy.assessment returns them.
  SYNTHETIC_ALLERGIES = {
    assessed: true, nka: false,
    allergies: [
      { ien: "1", allergen: "LATEX", severity: nil, signs: nil, altered: false },
      { ien: "2", allergen: "PENICILLIN", severity: nil, signs: nil, altered: false }
    ]
  }.freeze

  # The keys of a user every link of the main navigation shows to, and every
  # count of the dashboard: all three referral keys, registration (search and
  # setup) and scheduling. The patient-read scope shows Notifications and the
  # patient search.
  REFERRAL_KEYS = %w[referrals_user referrals_supervisor referrals_manager].freeze
  EVERY_KEY = (REFERRAL_KEYS + %w[registration_menu registration_manager scheduling_user scheduling_supervisor]).freeze
  NAV_LINKS = {
    "Notifications" => "/lakeraven-ehr/notifications", "Registration" => "/lakeraven-ehr/registration/patients",
    "Scheduling" => "/lakeraven-ehr/scheduling", "Referrals" => PENDING, "Setup" => "/lakeraven-ehr/registration/setup"
  }.freeze

  # Every form a referral surface may render, and the controls each may hold,
  # as [tag, type, name]. A control is allowed only inside the form it is
  # listed under: that method, that action path, and that id where one is
  # named. A control in no form is never allowed. The test environment
  # renders no authenticity_token; where forgery protection is on, Rails adds
  # one to each posting form.
  CSRF_TOKEN = %w[input hidden authenticity_token].freeze
  NAMELESS_SUBMIT = [ "input", "submit", "" ].freeze
  NAMELESS_BUTTON = [ "button", "submit", "" ].freeze
  METHOD_OVERRIDE = %w[input hidden _method].freeze
  SIGN_OUT_CONTROLS = [ NAMELESS_BUTTON, METHOD_OVERRIDE ].freeze
  WINDOW_CONTROLS = [ %w[input date from], %w[input date to], NAMELESS_SUBMIT ].freeze
  PENDING_CONTROLS = (WINDOW_CONTROLS + SIGN_OUT_CONTROLS).freeze
  SEARCH_CONTROLS = [ %w[input text q], NAMELESS_SUBMIT ].freeze
  Form = Data.define(:verb, :action, :id, :controls)
  FORMS = [
    # The date window of the pending list.
    Form.new("get", %r{\A/lakeraven-ehr/referrals/pending\z}, "referral-window", WINDOW_CONTROLS),
    # "Open chart" on a referral's row: opens that patient, by DFN in the path.
    Form.new("post", %r{\A/lakeraven-ehr/patients/\d+/context\z}, nil, [ NAMELESS_BUTTON, CSRF_TOKEN ]),
    # "Sign out".
    Form.new("post", %r{\A/lakeraven-ehr/logout\z}, nil, SIGN_OUT_CONTROLS + [ CSRF_TOKEN ]),
    # "Clear patient context" in the patient banner.
    Form.new("post", %r{\A/lakeraven-ehr/patient_context\z}, nil, [ NAMELESS_BUTTON, METHOD_OVERRIDE, CSRF_TOKEN ]),
    # The patient search of the empty banner: free text, never inspected.
    Form.new("post", %r{\A/lakeraven-ehr/chart_search\z}, "patient-search", SEARCH_CONTROLS + [ CSRF_TOKEN ])
  ].freeze

  # Never a referral surface's, whatever the allowlist says: a control that
  # offers a choice among named things, or sends its form somewhere else.
  CHOICE_TAGS = %w[select option optgroup datalist].freeze
  CHOICE_TYPES = %w[radio checkbox].freeze
  CONTROL_TAGS = %w[input select textarea button datalist option optgroup output].freeze
  FORM_OVERRIDES = %w[formaction formmethod].freeze

  # The only query parameters a URL on the page may carry, by the path that
  # carries them, and what they hold: the pending list's window, and the day
  # of a clinic the dashboard links a count to. Any other key, and either of
  # these on another path, is a choice.
  ISO_DATE = /\A(\d{4}-\d{2}-\d{2})?\z/
  A_DATE = /\A\d{4}-\d{2}-\d{2}\z/
  CLINIC_DAY = %r{\A/lakeraven-ehr/scheduling/clinics/\d+\z}
  ALLOWED_QUERY = {
    %r{\A/lakeraven-ehr/referrals/pending\z} => { "from" => ISO_DATE, "to" => ISO_DATE },
    CLINIC_DAY => { "date" => A_DATE }
  }.freeze
  URL_ATTRIBUTES = %w[href action formaction src].freeze

  # Rails' per-request random tokens: not words, and not read as words.
  RANDOM_TOKENS = [ "input[name='authenticity_token']", "meta[name='csrf-token']" ].freeze

  teardown { teardown_oauth! }

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "206", user_type: "provider", user_name: "PROFILE,MD", security_keys: keys }
  end

  # Answers the named RPCs on the stand-in's connection, the way
  # appointments_needing_action_test.rb does: a reply as it comes off the
  # wire, or an exception to raise.
  def rpms_answers(replies)
    client = RpmsRpc.client
    %i[call_rpc call_rpc_global_array].each do |name|
      original = client.method(name)
      client.define_singleton_method(name) do |rpc, *params|
        next original.call(rpc, *params) unless replies.key?(rpc)

        reply = replies[rpc]
        raise reply if reply.is_a?(Exception)

        reply.is_a?(Array) ? RpmsRpc::Reply.from_wire(reply) : reply
      end
    end
  end

  # What rpms-rpc's read of the pending referrals answers, whatever the window.
  def pending_answers(rows) = RpmsStandIn.answer(RpmsRpc::Referral, :pending) { |**| rows.map(&:dup) }

  # One rendered page, from a fresh session and a fresh stand-in for RPMS that
  # answers the two synthetic referrals unless the block says otherwise.
  # scopes: sign on with a SMART token too (the patient banner's reads), with
  # forgery protection on as a browser has it, so each posting form renders
  # its authenticity_token. patient: the DFN of a chart to open first.
  def page(path, keys: %w[referrals_user], scopes: nil, patient: nil, hour: 9, **params)
    reset!
    GlobalStoreIsolation.reset!
    enable_forgery_protection! if scopes
    pending_answers(SYNTHETIC_PENDING)
    yield if block_given?
    travel_to(TODAY.to_time.change(hour: hour)) do
      scopes ? sign_in_clinician!(scopes: scopes, keys: keys) : sign_in(keys.join(","))
      open_patient_context!(patient) if patient
      get path, params: params
    end
    assert_response :ok
    Nokogiri::HTML5(response.body)
  ensure
    restore_forgery_protection!
  end

  def shown!(document, selector, text = //, state)
    node = document.at_css(selector)

    assert node, "#{state}: #{selector} was not rendered, so the state was not checked"
    assert_match text, node.text.squish, "#{state}: #{selector}"
    document
  end

  # The page's own referral content, in a state that is about something else
  # (the navigation, the banner): both synthetic rows on the pending list,
  # their count on the dashboard, and no fallback to an unread read.
  def referrals_shown!(document, path, state)
    assert_empty document.css("#pending-referrals-unread, #referral-counts-unread"), "#{state}: the referrals were read"
    if path == PENDING
      assert_equal 2, document.css("#pending-referrals tr[data-referral]").size, "#{state}: both synthetic referrals are listed"
      shown!(document, "#pending-referrals tr[data-referral]", /CHARLIE,JORDAN/, state)
    else
      shown!(document, "#referral-counts td[data-count='2']", /2 referrals pending/, state)
    end
  end

  # The states the first three rounds checked: rows, with and without a
  # chosen window, and the dashboard's count of them.

  def pending_rows(**params)
    shown!(page(PENDING, **params), "#pending-referrals tr[data-referral]", /CHARLIE,JORDAN/, "pending rows")
  end

  def dashboard_count
    shown!(page(DASHBOARD), "#referral-counts td[data-count='2']", /2 referrals pending/, "dashboard count")
  end

  # RPMS answers no rows.
  def pending_empty
    shown!(page(PENDING) { pending_answers([]) }, "#no-pending-referrals", /No referrals initiated from .* are pending/, "empty list")
  end

  # The read of the pending referrals raises: nothing else of RPMS does.
  def unread(path, error, selector, text)
    document = page(path) { RpmsStandIn.answer(RpmsRpc::Referral, :pending) { |**| raise error } }

    assert_empty document.css("#pending-referrals, #no-pending-referrals, #referral-counts"), "#{error.class}: a failed read shows no list or count"
    shown!(document, selector, text, error.class.name)
  end

  def pending_unread(error = RpmsRpc::Client::RpcError.new("broker timeout"))
    unread(PENDING, error, "#pending-referrals-unread", /Pending referrals could not be read from RPMS/)
  end

  def pending_refused
    unread(PENDING, RpmsRpc::Client::RpcRefusedError.new("Access denied for remote procedure: BMC SEARCH REFERRAL"),
      "#pending-referrals-unread", /RPMS refused to list the pending referrals: Access denied for remote procedure: BMC SEARCH REFERRAL/)
  end

  def dashboard_unread(error = RpmsRpc::Client::RpcError.new("broker timeout"))
    unread(DASHBOARD, error, "#referral-counts-unread", /Pending referrals could not be read from RPMS/)
  end

  # A window RPMS is never asked for: the error is named next to the field.
  def pending_invalid_window(**dates)
    document = shown!(page(PENDING, **dates), "#from_error", /\S/, "invalid window #{dates}")

    assert_empty document.css("#pending-referrals, #no-pending-referrals, #pending-referrals-unread"), "#{dates}: no list is read"
    shown!(document, "#from[aria-invalid='true']", "invalid window #{dates}")
  end

  # Every capability at once: each link of the main navigation, and on the
  # dashboard every count, with rows RPMS answered. The hour is past the
  # first appointment's time, so one needs action.
  def every_capability(path)
    document = page(path, keys: EVERY_KEY, scopes: BANNER_SCOPES, hour: 15) do
      rpms_answers(SYNTHETIC_SCHEDULING)
      RpmsStandIn.answer(RpmsRpc::Notifications, :inbox) { |**| SYNTHETIC_ALERTS.map(&:dup) }
    end

    assert_equal NAV_LINKS, document.css("nav[aria-label='Main'] a").to_h { |a| [ a.text.squish, a["href"] ] }, "#{path}: every link of the navigation"
    shown!(document, "#patient-banner form#patient-search input[name='q']", "every capability")
    referrals_shown!(document, path, "every capability")
  end

  def dashboard_every_count
    document = every_capability(DASHBOARD)

    assert_empty document.css("[id$='-unread'], #no-counts, #no-clinics"), "every count is one RPMS answered"
    assert_equal [ "/lakeraven-ehr/scheduling/clinics/1?date=2026-11-04", "/lakeraven-ehr/scheduling/clinics/2?date=2026-11-04" ],
      document.css("#clinic-counts tr[data-resource] a").map { |a| a["href"] }
    shown!(document, "#clinic-counts tr[data-resource='2'] td[data-count='2']", /2 appointments today at SYNTHETIC CLINIC B/, "clinic counts")
    shown!(document, "#needing-action-count[data-count='1'] a[href='/lakeraven-ehr/scheduling/needing_action']", "needing action")
    shown!(document, "#notification-count[data-count='2'] a[href='/lakeraven-ehr/notifications']", "notifications")
    shown!(document, "#referral-counts td[data-count='2']", "referral count")
  end

  # A chart open in the session: the banner names the patient and their
  # allergies, and offers another patient or none.
  def patient_open(path)
    document = page(path, keys: REFERRAL_KEYS, scopes: BANNER_SCOPES, patient: 1) { RpmsStandIn.answer(RpmsRpc::Allergy, :assessment, 1, with: SYNTHETIC_ALLERGIES) }
    banner = "#patient-banner"

    shown!(document, "#{banner} .patient-banner__name", /\S/, "patient open")
    shown!(document, "#{banner} dl.demoinfo", /DOB.*Age.*Sex.*MRN/, "patient open")
    shown!(document, "#{banner} [data-allergies-state='loaded']", /Allergies\s*LATEX\s*PENICILLIN/i, "patient open")
    shown!(document, "#{banner} a#switch-patient[href='/lakeraven-ehr/chart_search']", /Switch patient/, "patient open")
    shown!(document, "#{banner} form[action$='/lakeraven-ehr/patient_context'] button", /Clear patient context/, "patient open")
    referrals_shown!(document, path, "patient open")
  end

  # No chart open, and a user who may search patients: the banner is the search.
  def patient_search(path)
    document = page(path, keys: REFERRAL_KEYS, scopes: BANNER_SCOPES)

    assert_equal SEARCH_CONTROLS, controls(document.at_css("form#patient-search")) - [ CSRF_TOKEN ], "the search is its field and a submit"
    shown!(document, "form#patient-search[action='/lakeraven-ehr/chart_search'][method='post'] a#recent-patients-link", /Recent patients/, "patient search")
    referrals_shown!(document, path, "patient search")
  end

  # Every state of the two pages, rendered. Each proves itself rendered
  # before it is returned.
  def pages
    {
      "the pending referrals" => pending_rows,
      "the pending referrals of a chosen window" => pending_rows(from: "2026-11-01", to: "2026-11-02"),
      "no pending referrals" => pending_empty,
      "the pending referrals RPMS did not answer" => pending_unread,
      "the pending referrals a dropped connection left unread" => pending_unread(IOError.new("closed stream")),
      "the pending referrals RPMS refused" => pending_refused,
      "the pending referrals of a window the wrong way round" => pending_invalid_window(from: "2026-11-05", to: "2026-11-01"),
      "the pending referrals of a date that is not one" => pending_invalid_window(from: "2026-13-01", to: "2026-11-02"),
      "the pending referrals of a user with every capability" => every_capability(PENDING),
      "the pending referrals with a chart open" => patient_open(PENDING),
      "the pending referrals with the patient search" => patient_search(PENDING),
      "the dashboard" => dashboard_count,
      "the dashboard RPMS did not answer" => dashboard_unread,
      "the dashboard a dropped connection left unread" => dashboard_unread(IOError.new("closed stream")),
      "the dashboard of a user with every capability" => dashboard_every_count,
      "the dashboard with a chart open" => patient_open(DASHBOARD),
      "the dashboard with the patient search" => patient_search(DASHBOARD)
    }
  end

  def control_nodes(document) = document.css(CONTROL_TAGS.join(",")) | document.css("form [name]")

  # Every form control in a document, as [tag, type, name].
  def controls(document)
    control_nodes(document).map { |node| [ node.name, node["type"].to_s.downcase, node["name"].to_s ] }
  end

  # The form a control is sent with: the one its form attribute names, or
  # the one it is inside.
  def form_of(node)
    return node.document.css("form").find { |form| form["id"] == node["form"] } if node["form"]

    node.ancestors("form").first
  end

  # Every control sent with a form, as [tag, type, name]: those inside it,
  # and those anywhere on the page its id is named by in a form attribute.
  def controls_of(form)
    named = form["id"].present? ? control_nodes(form.document).select { |node| node["form"] == form["id"] } : []
    (control_nodes(form).to_a | named).map { |node| [ node.name, node["type"].to_s.downcase, node["name"].to_s ] }
  end

  # Every listed form among these that is not exactly its listed controls.
  def inexact_forms(forms)
    forms.filter_map do |form|
      next "#{form['method']} #{form['action']}: not a listed form" unless listed(form)

      expected = (listed(form).controls - [ CSRF_TOKEN ]).sort
      found = (controls_of(form) - [ CSRF_TOKEN ]).sort
      "#{form['method']} #{form['action']}: #{found.inspect}, not #{expected.inspect}" unless found == expected
    end
  end

  def path_of(url) = url.to_s.strip.sub(%r{\Ahttps?://[^/?#]*}i, "")[/\A[^?#]*/]

  # The listed form a form on the page is, if any.
  def listed(form)
    return if form.nil?

    verb = form["method"].to_s.downcase.presence || "get"
    FORMS.find { |known| known.verb == verb && path_of(form["action"]).match?(known.action) && (known.id.nil? || known.id == form["id"]) }
  end

  # Every control that is not one its own form is listed with, as
  # [form, tag, type, name].
  def disallowed_controls(document)
    control_nodes(document).filter_map do |node|
      control = [ node.name, node["type"].to_s.downcase, node["name"].to_s ]
      form = form_of(node)
      allowed = listed(form)&.controls&.include?(control) && CHOICE_TAGS.exclude?(control[0]) && CHOICE_TYPES.exclude?(control[1]) &&
        FORM_OVERRIDES.none? { |attribute| node.key?(attribute) }
      [ form ? "#{form['method'] || 'get'} #{form['action']}" : "no form", *control ] unless allowed
    end
  end

  # Every attribute read as a URL: any href, action, formaction or src, and
  # any other attribute (a data-* one, say) whose value is a path or a URL.
  def url_attributes(document)
    document.xpath("//@*").select do |attribute|
      URL_ATTRIBUTES.include?(attribute.name) || attribute.value.strip.match?(%r{\A(/|https?:)})
    end
  end

  # Every URL on the page that carries a query parameter its path is not
  # listed with: any href, action, formaction or src, and any other attribute
  # whose value is a path or a URL.
  def urls_carrying_a_choice(document)
    url_attributes(document).filter_map do |attribute|
      url = attribute.value.strip
      query = url[/\?([^#]*)/, 1]
      next if query.nil?

      allowed = ALLOWED_QUERY.find { |path, _keys| path_of(url).match?(path) }&.last || {}
      carried = Rack::Utils.parse_query(query)
      "#{attribute.name}=#{url}" unless carried.all? { |key, value| allowed.key?(key) && value.to_s.match?(allowed[key]) }
    end
  end

  # The SUD words in the page's text (scripts and styles included) and in
  # every attribute value, each with where it was found. The text is read
  # twice: each text node on its own, so a whole word in one element is not
  # fused with its neighbour's (<li>MH</li><li>SUD</li> is not "MHSUD"), and
  # the page's text as one, so a phrase split across elements still reads.
  def sud_words_on(document)
    skipped = RANDOM_TOKENS.flat_map { |selector| document.css(selector).to_a }
    attributes = document.xpath("//@*").reject { |attribute| skipped.include?(attribute.parent) }
    nodes = document.xpath("//text()").map { |node| [ "text of #{node.parent&.name}", node.text ] }
    texts = [ [ "text", document.text ] ] + nodes + attributes.map { |attribute| [ "#{attribute.parent.name}[#{attribute.name}]", attribute.value ] }
    texts.flat_map { |where, text| SudWords.hits(text).map { |hit| "#{where}: #{hit} in #{text.squish.truncate(80)}" } }.uniq
  end

  def html(fragment)
    Nokogiri::HTML5("<!DOCTYPE html><html><body>#{fragment}</body></html>")
  end

  test "#905 every form control a referral surface renders is on the allowlist" do
    pages.each do |name, document|
      assert_empty disallowed_controls(document),
        "#{name} render a form control its form is not listed with"
      assert_empty document.css(CHOICE_TAGS.join(",")), "#{name} offer a choice"
    end
  end

  test "#905 the pending referrals render exactly the date window, its submit, and the chart and sign-out buttons" do
    [ page(PENDING), page(PENDING, from: "2026-11-01", to: "2026-11-02") ].each do |document|
      assert_not_empty controls(document), "no form control found: the guard is looking at nothing"
      assert_equal PENDING_CONTROLS.sort, (controls(document).uniq - [ CSRF_TOKEN ]).sort
      assert_equal [ %w[input date from], %w[input date to], [ "input", "submit", "" ] ],
        controls(document.at_css("form#referral-window")), "the window is its two dates and a submit"
      assert_equal 2, document.css("#pending-referrals tr[data-referral] form button").size, "one chart button per referral"
    end
  end

  test "#905 the dashboard renders no form control but the sign-out button" do
    document = page(DASHBOARD)

    assert_predicate document.at_css("#referral-counts"), :present?, "the dashboard shows no referral count: the guard is looking at nothing"
    assert_equal SIGN_OUT_CONTROLS.sort, (controls(document) - [ CSRF_TOKEN ]).sort
  end

  test "#905 no URL a referral surface renders carries a parameter its path is not listed with" do
    pages.each do |name, document|
      assert_not_empty document.css("a[href], form[action]"), "#{name}: no link or form found"
      assert_empty urls_carrying_a_choice(document), "#{name} carry a choice in a URL"
    end
  end

  test "#905 the only query parameters rendered are the window's dates and a clinic's day" do
    carried = pages.values.flat_map { |document| url_attributes(document).map { |attribute| attribute.value.strip }.grep(/\?/) }.uniq

    assert_equal [ "/lakeraven-ehr/scheduling/clinics/1?date=2026-11-04", "/lakeraven-ehr/scheduling/clinics/2?date=2026-11-04" ], carried.sort,
      "the dashboard links each clinic's count to that clinic's day, today; nothing else carries a parameter"
  end

  test "#905 across every state the pages render only the listed forms, each with exactly its controls" do
    rendered = pages.values.flat_map { |document| document.css("form").to_a }
    forms = rendered.group_by { |form| listed(form) }

    assert_equal FORMS.to_set, forms.keys.to_set, "every listed form is rendered in some state, and no other form is"
    assert_empty inexact_forms(rendered), "a form holds, or is sent with, a control it is not listed with, or lacks one"
  end

  test "#905 the text and attributes a referral surface renders name no SUD path" do
    pages.each do |name, document|
      assert_operator document.text.squish.size, :>, 100, "#{name}: no text found"
      assert_empty sud_words_on(document), "#{name} name an SUD path"
    end
  end

  # The checker itself, fed what it must catch.

  test "#905 the rendered check flags a control that offers a choice, however it is named" do
    {
      %(<form><select name="referral_type"><option value="7">Program A</option></select></form>) =>
        [ %w[select referral_type], [ "option", "" ] ],
      %(<select name="from"><option>2026-11-01</option></select>) => [ %w[select from], [ "option", "" ] ],
      %(<form><input type="radio" name="kind" value="7"></form>) => [ %w[input kind] ],
      %(<input type="checkbox" name="from">) => [ %w[input from] ],
      %(<input list="kinds" name="to" type="date"><datalist id="kinds"><option value="7"></datalist>) => [ [ "datalist", "" ] ],
      %(<form><input type="hidden" name="referral_type" value="7"></form>) => [ %w[input referral_type] ],
      %(<input type="date" name="referral[from]">) => [ %w[input referral[from]] ],
      %(<input name="from">) => [ %w[input from] ],
      %(<textarea name="notes"></textarea>) => [ %w[textarea notes] ],
      %(<button name="kind" value="7">Refer</button>) => [ %w[button kind] ],
      %(<form><input type="submit" name="kind" value="Program A"></form>) => [ %w[input kind] ],
      %(<form><div name="kind" contenteditable>7</div></form>) => [ %w[div kind] ]
    }.each do |fragment, expected|
      flagged = disallowed_controls(html(fragment)).map { |_form, tag, _type, name| [ tag, name ] }

      expected.each { |control| assert_includes flagged, control, fragment }
    end
  end

  test "#905 the rendered check allows the date window and the Rails buttons" do
    window = <<~HTML
      <form id="referral-window" action="/lakeraven-ehr/referrals/pending" method="get">
        <label for="from">Initiated from</label><input type="date" name="from" id="from" value="2026-11-01">
        <label for="to">Initiated to</label><input type="date" name="to" id="to">
        <input type="submit" value="Show referrals">
      </form>
      <form class="button_to" method="post" action="/lakeraven-ehr/logout">
        <input type="hidden" name="_method" value="delete"><button type="submit">Sign out</button>
        <input type="hidden" name="authenticity_token" value="synthetic">
      </form>
      <a href="/lakeraven-ehr/referrals/pending?from=2026-11-01&amp;to=2026-11-02">Referrals</a>
      <a href="/lakeraven-ehr/referrals/pending?from=&amp;to=">Referrals</a>
    HTML

    assert_equal 6, controls(html(window)).size
    assert_empty disallowed_controls(html(window))
    assert_empty urls_carrying_a_choice(html(window))
    assert_empty sud_words_on(html(window))
  end

  test "#905 the rendered check allows the chart button, the patient search, clearing the patient and a clinic's day" do
    banner = <<~HTML
      <form class="button_to" method="post" action="/lakeraven-ehr/patients/990003/context">
        <button type="submit">Open chart</button><input type="hidden" name="authenticity_token" value="synthetic">
      </form>
      <form id="patient-search" role="search" action="/lakeraven-ehr/chart_search" method="post">
        <input type="hidden" name="authenticity_token" value="synthetic">
        <input type="text" name="q" id="patient_search_q" required><input type="submit" value="Find patient">
      </form>
      <form class="button_to" method="post" action="http://www.example.com/lakeraven-ehr/patient_context">
        <input type="hidden" name="_method" value="delete"><button type="submit">Clear patient context</button>
      </form>
      <a href="/lakeraven-ehr/scheduling/clinics/2?date=2026-11-04">2 appointments</a>
    HTML

    assert_equal 7, controls(html(banner)).size
    assert_empty disallowed_controls(html(banner))
    assert_empty urls_carrying_a_choice(html(banner))
    assert_empty sud_words_on(html(banner))
  end

  test "#905 the rendered check flags an allowed control in a form it is not listed with, or in none" do
    {
      # The search field, sent anywhere but the chart search, or from another form there.
      %(<form id="patient-search" method="post" action="/lakeraven-ehr/referrals"><input type="text" name="q"></form>) => %w[input text q],
      %(<form id="patient-search" method="get" action="/lakeraven-ehr/chart_search"><input type="text" name="q"></form>) => %w[input text q],
      %(<form id="refer" method="post" action="/lakeraven-ehr/chart_search"><input type="text" name="q"></form>) => %w[input text q],
      %(<form id="referral-window" method="get" action="/lakeraven-ehr/referrals/pending"><input type="text" name="q"></form>) => %w[input text q],
      %(<input type="text" name="q">) => %w[input text q],
      # A nameless submit in a form that is not one of the five.
      %(<form method="post" action="/lakeraven-ehr/referrals"><input type="submit" value="Refer"></form>) => NAMELESS_SUBMIT,
      %(<form method="post" action="/lakeraven-ehr/referrals"><button type="submit">Refer</button></form>) => NAMELESS_BUTTON,
      %(<form method="post" action="/lakeraven-ehr/patients/990003/referrals"><button type="submit">Refer</button></form>) => NAMELESS_BUTTON,
      %(<form><input type="submit" value="Refer"></form>) => NAMELESS_SUBMIT,
      %(<button type="submit">Refer</button>) => NAMELESS_BUTTON,
      # The window's dates outside the window, or posted.
      %(<form method="post" action="/lakeraven-ehr/logout"><input type="date" name="from"></form>) => %w[input date from],
      %(<form id="referral-window" method="post" action="/lakeraven-ehr/referrals/pending"><input type="date" name="to"></form>) => %w[input date to],
      %(<form id="other" method="get" action="/lakeraven-ehr/referrals/pending"><input type="date" name="to"></form>) => %w[input date to],
      # A control a listed form does not hold, or one that leaves its form.
      %(<form method="post" action="/lakeraven-ehr/logout"><input type="text" name="q"></form>) => %w[input text q],
      %(<form method="post" action="/lakeraven-ehr/logout"><button type="submit" formaction="/lakeraven-ehr/referrals">Refer</button></form>) => NAMELESS_BUTTON,
      %(<form id="patient-search" method="post" action="/lakeraven-ehr/chart_search"></form><input type="text" name="q" form="other">) => %w[input text q],
      %(<form method="post" action="/lakeraven-ehr/referrals" id="refer"></form><form method="post" action="/lakeraven-ehr/logout"><button type="submit" form="refer">Refer</button></form>) => NAMELESS_BUTTON
    }.each do |fragment, control|
      assert_includes disallowed_controls(html(fragment)).map { |_form, *flagged| flagged }, control, fragment
    end
  end

  test "#905 the exact-controls check counts a control sent with a form from outside it" do
    window = %(<form id="referral-window" action="/lakeraven-ehr/referrals/pending" method="get">) +
      %(<input type="date" name="from"><input type="date" name="to"><input type="submit" value="Show referrals"></form>)

    assert_empty inexact_forms(html(window).css("form"))
    [
      %(#{window}<input type="date" name="from" form="referral-window">),
      %(<div><input type="date" name="to" form="referral-window"></div>#{window}),
      %(#{window}<form method="post" action="/lakeraven-ehr/logout"><button type="submit" form="referral-window">Go</button></form>),
      window.sub(%(<input type="date" name="to">), ""),
      window.sub("</form>", %(<input type="date" name="from"></form>))
    ].each { |fragment| assert_not_empty inexact_forms(html(fragment).css("form#referral-window")), fragment }
  end

  test "#905 the rendered check flags a known parameter on a path it is not listed with" do
    [
      %(<a href="/lakeraven-ehr/referrals/pending?date=2026-11-04">Referrals</a>),
      %(<a href="/lakeraven-ehr/scheduling/clinics/2?from=2026-11-01">Clinic</a>),
      %(<a href="/lakeraven-ehr/scheduling/clinics/2?date=2026-11-04&amp;to=2026-11-05">Clinic</a>),
      %(<a href="/lakeraven-ehr/scheduling/clinics/2?date=">Clinic</a>),
      %(<a href="/lakeraven-ehr/scheduling/clinics/2?date=7">Clinic</a>),
      %(<a href="/lakeraven-ehr/scheduling/clinics/2?date=2026-11-04&amp;kind=7">Clinic</a>),
      %(<a href="/lakeraven-ehr/scheduling/clinics/2/week?date=2026-11-04">Clinic</a>),
      %(<a href="/lakeraven-ehr/scheduling?date=2026-11-04">Scheduling</a>),
      %(<a href="/lakeraven-ehr/referrals?from=2026-11-01">Referrals</a>),
      %(<a href="/lakeraven-ehr/referrals/pending/7?from=2026-11-01">Referrals</a>),
      %(<a href="/lakeraven-ehr/dashboard?from=2026-11-01&amp;to=2026-11-02">Dashboard</a>),
      %(<a href="/lakeraven-ehr/chart_search?q=7">Find</a>),
      %(<form action="/lakeraven-ehr/chart_search?date=2026-11-04"></form>)
    ].each { |fragment| assert_not_empty urls_carrying_a_choice(html(fragment)), fragment }
  end

  test "#905 the rendered check flags a URL that carries a choice" do
    [
      %(<a href="/referrals/pending?kind=7">Program A</a>),
      %(<a href="/referrals/pending?from=2026-11-01&amp;kind=7">Program A</a>),
      %(<a href="/referrals/pending?from=7">Program A</a>),
      %(<a href="https://ehr.test.example/referrals/pending?to[]=7#list">Program A</a>),
      %(<form action="/referrals/pending?referral_type=7"></form>),
      %(<form><button formaction="/referrals?kind=7">Refer</button></form>),
      %(<div data-url="/referrals/pending?kind=7"></div>),
      %(<iframe src="referrals?kind=7"></iframe>)
    ].each { |fragment| assert_not_empty urls_carrying_a_choice(html(fragment)), fragment }
  end

  test "#905 the rendered check reads SUD words in text, attributes, scripts and styles" do
    [
      %(<p>Refer to the opioid treatment program</p>), %(<a href="/referrals/sud">Refer</a>),
      %(<button data-kind="matreferral">Refer</button>), %(<input type="hidden" name="kind" value="SudReferral">),
      %(<img alt="Sober living">), %(<script>var kinds = ["detox"];</script>), %(<style>.oud-program { color: red }</style>),
      %(<input type="hidden" name="other" value="naltrexone">)
    ].each { |fragment| assert_not_empty sud_words_on(html(fragment)), fragment }

    # A whole word in its own element, next to an element it would fuse with.
    [
      %(<ul><li>MH</li><li>SUD</li></ul>), %(<table><tr><th>SUD</th><th>clinic</th></tr></table>),
      %(<p>the <b>use</b> <i>disorder</i> clinic</p>)
    ].each { |fragment| assert_not_empty sud_words_on(html(fragment)), fragment }

    assert_empty sud_words_on(html(%(<p class="format">Audit the material</p><a href="/sudo/audit">Referrals pending</a>)))
  end
end
