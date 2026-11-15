# frozen_string_literal: true

require "test_helper"
require_relative "../support/sud_words"

# #905 (slice of #522): the December build is MH/BH only, so the referral
# surfaces offer no structured SUD path. Proven on what the pages render:
# the whole response, layout and every partial and helper included, however
# a control was built. RPMS is stood in for at the wire, as in
# test/integration/pending_referrals_test.rb.
class ReferralSurfacesRenderedTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  TODAY = Date.new(2026, 11, 4)
  PENDING = "/lakeraven-ehr/referrals/pending"
  DASHBOARD = "/lakeraven-ehr/dashboard"

  # Two synthetic referrals, in the shape BMC SEARCH REFERRAL answers.
  SYNTHETIC_PENDING =
    "~`1^NOV 01, 2026^^990003^CHARLIE,JORDAN^^^<UNKNOWN>^^ACTIVE^^^DIRECT ONLY^^^^^^^^^^06/03/1966^^" \
    "~`2^NOV 01, 2026^^990003^CHARLIE,JORDAN^^^<UNKNOWN>^^APPROVED^^^DIRECT ONLY^^^^^^^^^^06/03/1966^^"

  # Every form control a referral surface may render, as [tag, type, name]:
  # the date window and its submit, the buttons that open a chart and sign
  # out, and the hidden fields Rails gives those buttons' forms. The test
  # environment renders no authenticity_token; where forgery protection is
  # on, Rails adds one to each button's form.
  CSRF_TOKEN = %w[input hidden authenticity_token].freeze
  SIGN_OUT_CONTROLS = [ [ "button", "submit", "" ], %w[input hidden _method] ].freeze
  PENDING_CONTROLS = ([ %w[input date from], %w[input date to], [ "input", "submit", "" ] ] + SIGN_OUT_CONTROLS).freeze
  ALLOWED_CONTROLS = (PENDING_CONTROLS + [ CSRF_TOKEN ]).freeze

  # Never a referral surface's, whatever the allowlist says: a control that
  # offers a choice among named things.
  CHOICE_TAGS = %w[select option optgroup datalist].freeze
  CHOICE_TYPES = %w[radio checkbox].freeze
  CONTROL_TAGS = %w[input select textarea button datalist option optgroup output].freeze

  # The only query parameters a URL on the page may carry, and what they hold.
  ALLOWED_QUERY = %w[from to].freeze
  ISO_DATE = /\A(\d{4}-\d{2}-\d{2})?\z/
  URL_ATTRIBUTES = %w[href action formaction src].freeze

  # Rails' per-request random tokens: not words, and not read as words.
  RANDOM_TOKENS = [ "input[name='authenticity_token']", "meta[name='csrf-token']" ].freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "206", user_type: "provider", user_name: "PROFILE,MD", security_keys: keys }
  end

  # The whole rendered page, with RPMS answering the two synthetic referrals.
  def page(path, **params)
    RpmsRpc.client.seed_raw_lines(:referral_search, "", [ SYNTHETIC_PENDING ])
    sign_in("referrals_user")
    travel_to(TODAY.to_time.change(hour: 9)) { get path, params: params }
    assert_response :ok
    Nokogiri::HTML5(response.body)
  end

  def pages
    {
      "the pending referrals" => page(PENDING),
      "the pending referrals of a chosen window" => page(PENDING, from: "2026-11-01", to: "2026-11-02"),
      "the dashboard" => page(DASHBOARD)
    }
  end

  # Every form control in a document, as [tag, type, name].
  def controls(document)
    (document.css(CONTROL_TAGS.join(",")) | document.css("form [name]")).map do |node|
      [ node.name, node["type"].to_s.downcase, node["name"].to_s ]
    end
  end

  def disallowed_controls(document)
    controls(document).reject do |control|
      ALLOWED_CONTROLS.include?(control) && CHOICE_TAGS.exclude?(control[0]) && CHOICE_TYPES.exclude?(control[1])
    end
  end

  # Every URL on the page that carries a query parameter other than a from
  # or to date: any href, action, formaction or src, and any other attribute
  # whose value is a path or a URL.
  def urls_carrying_a_choice(document)
    document.xpath("//@*").filter_map do |attribute|
      url = attribute.value.strip
      next unless URL_ATTRIBUTES.include?(attribute.name) || url.match?(%r{\A(/|https?:)})

      query = url[/\?([^#]*)/, 1]
      next if query.nil?

      carried = Rack::Utils.parse_query(query)
      "#{attribute.name}=#{url}" unless carried.all? { |key, value| ALLOWED_QUERY.include?(key) && value.to_s.match?(ISO_DATE) }
    end
  end

  # The SUD words in the page's text (scripts and styles included) and in
  # every attribute value, each with where it was found.
  def sud_words_on(document)
    skipped = RANDOM_TOKENS.flat_map { |selector| document.css(selector).to_a }
    attributes = document.xpath("//@*").reject { |attribute| skipped.include?(attribute.parent) }
    texts = [ [ "text", document.text ] ] + attributes.map { |attribute| [ "#{attribute.parent.name}[#{attribute.name}]", attribute.value ] }
    texts.flat_map { |where, text| SudWords.hits(text).map { |hit| "#{where}: #{hit} in #{text.squish.truncate(80)}" } }
  end

  def html(fragment)
    Nokogiri::HTML5("<!DOCTYPE html><html><body>#{fragment}</body></html>")
  end

  test "#905 every form control a referral surface renders is on the allowlist" do
    pages.each do |name, document|
      assert_empty disallowed_controls(document),
        "#{name} render a form control that is not on the allowlist #{ALLOWED_CONTROLS.inspect}"
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

  test "#905 no link or form action on a referral surface carries a parameter other than a from or to date" do
    pages.each do |name, document|
      assert_not_empty document.css("a[href], form[action]"), "#{name}: no link or form found"
      assert_empty urls_carrying_a_choice(document), "#{name} carry a choice in a URL"
    end
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
      flagged = disallowed_controls(html(fragment)).map { |tag, _type, name| [ tag, name ] }

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
    HTML

    assert_equal 6, controls(html(window)).size
    assert_empty disallowed_controls(html(window))
    assert_empty urls_carrying_a_choice(html(window))
    assert_empty sud_words_on(html(window))
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

    assert_empty sud_words_on(html(%(<p class="format">Audit the material</p><a href="/sudo/audit">Referrals pending</a>)))
  end
end
