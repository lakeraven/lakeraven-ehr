# frozen_string_literal: true

require "test_helper"

# Synthetic RPMS boundary; these tests do not establish live RPMS parity.
class SchedulingClinicProvidersTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper
  include BrowserFormHelper

  BASE = "/lakeraven-ehr/scheduling/clinics/5/providers"
  RESOURCE = { id: 5, name: "DEMO PODIATRY", inactive: false, hospital_location_id: 11,
               view: true, modify_schedule: true, modify_appointments: true }.freeze
  PROVIDERS = [ { id: 1, duz: 206, name: "ALPHA,PROVIDER", default: true },
                { id: 2, duz: 207, name: "BETA,PROVIDER", default: false } ].freeze
  SETTINGS = { id: 11, name: "DEMO PODIATRY", create_visit_at_checkin: true,
               visit_provider_required: true, providers: PROVIDERS }.freeze

  def sign_in(keys = "scheduling_supervisor")
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_type: "user", user_name: "MANAGER,SYSTEM", security_keys: keys }
  end

  def with_rpms(resources: [ RESOURCE ], reads: nil, outcome: { success: true }, apply: true)
    @providers = PROVIDERS.map(&:dup)
    @events = []
    owner = self
    queue = reads&.dup
    stubs = {
      RpmsRpc::Scheduling.singleton_class => { resources: ->(*) { resources } },
      RpmsRpc::SchedulingSetup.singleton_class => {
        clinic_settings: ->(_id) { SETTINGS.merge(providers: owner.providers) },
        clinic_providers: lambda { |id|
          owner.events << [ :read, id.to_i ]
          value = queue && !queue.empty? ? queue.shift : owner.providers.map(&:dup)
          raise value if value.is_a?(Exception)
          value
        },
        set_default_provider: lambda { |hospital_location_id:, entry_id:|
          owner.events << [ :default, hospital_location_id.to_i, entry_id.to_i ]
          raise outcome if outcome.is_a?(Exception)
          owner.providers.each { |p| p[:default] = p[:id] == entry_id.to_i } if apply && outcome == { success: true }
          outcome
        },
        remove_clinic_provider: lambda { |hospital_location_id:, entry_id:|
          owner.events << [ :remove, hospital_location_id.to_i, entry_id.to_i ]
          raise outcome if outcome.is_a?(Exception)
          owner.providers.reject! { |p| p[:id] == entry_id.to_i } if apply && outcome == { success: true }
          outcome
        }
      }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  attr_reader :providers, :events

  def follow_if_redirected
    follow_redirect! if response.redirect?
  end

  def assert_no_writes
    assert_empty events.select { |event| %i[default remove].include?(event.first) }
  end

  def assert_unconfirmed
    follow_if_redirected
    assert_match(/(unable|unavailable|could not|not confirm|not saved|refus|failed|error)/i, response.body)
    refute_match(/(successfully|provider (?:was )?(?:saved|removed)|default (?:was )?(?:set|saved))/i, response.body)
    refute_includes response.body, "RAW BROKER SECRET"
  end

  test "settings links to the scoped list, and a scheduling reader sees providers without write controls" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5/settings"
      assert_response :success
      assert_select "a[href='#{BASE}']"
      get BASE
      assert_response :success
      assert_match(/ALPHA,PROVIDER/, response.body)
      assert_match(/BETA,PROVIDER/, response.body)
      assert_match(/default/i, response.body)
      assert_select "form[action*='/providers/']", count: 0
      assert_includes events, [ :read, 11 ]
    end
  end

  test "supervisor forms use POST and DELETE conventions and offer removal confirmation" do
    sign_in
    with_rpms do
      get BASE
      assert_response :success
      assert_select "form[action='#{BASE}/2/default'][method='post']"
      assert_select "form[action='#{BASE}/1'][method='post']" do
        assert_select "input[name='_method'][value='delete']"
      end
      assert_match(/(confirm|are you sure)/i, response.body)
    end
  end

  test "removal forms have one submit and a separate required confirmation" do
    sign_in
    with_rpms do
      with_forgery_protection do
        get BASE
        assert_response :success
        document = Nokogiri::HTML5.parse(response.body)
        [ 1, 2 ].each do |id|
          form = document.at_css("form[action='#{BASE}/#{id}']")
          assert form, "missing removal form for #{id}"
          assert_equal "post", form["method"]
          assert_equal "delete", form.at_css("input[name='_method']")&.[]("value")
          assert form.at_css("input[name='authenticity_token']")
          assert_equal 1, form.css("button:not([type]), button[type='submit'], input[type='submit']").size
          confirmation = form.at_css("input[type='checkbox'][name='confirm_removal'][required]")
          assert confirmation
          assert_empty confirmation.ancestors("button")
        end
      end
    end
  end

  test "supervisor changes default only after membership read and confirms fresh sole default" do
    sign_in
    with_rpms do
      post "#{BASE}/2/default", params: { duz: 999, hospital_location_id: 999 }
      assert_response :redirect
      follow_redirect!
      assert_match(/(saved|set|updated|default)/i, response.body)
      write = events.index([ :default, 11, 2 ])
      assert write, events.inspect
      assert_includes events[0...write], [ :read, 11 ]
      assert_includes events[(write + 1)..], [ :read, 11 ]
      assert_equal [ 2 ], providers.select { |p| p[:default] }.map { |p| p[:id] }
    end
  end

  test "supervisor removes a member after membership read and confirms absence; default warning remains" do
    sign_in
    with_rpms do
      delete "#{BASE}/1", params: { duz: 999, hospital_location_id: 999 }
      assert_response :redirect
      follow_redirect!
      write = events.index([ :remove, 11, 1 ])
      assert write, events.inspect
      assert_includes events[0...write], [ :read, 11 ]
      assert_includes events[(write + 1)..], [ :read, 11 ]
      refute providers.any? { |p| p[:id] == 1 }
      get "/lakeraven-ehr/scheduling/clinics/5/settings"
      assert_select "#default-provider-warning", text: /no default provider/i
    end
  end

  test "reader cannot mutate via direct requests" do
    sign_in("scheduling_user")
    with_rpms do
      post "#{BASE}/2/default"
      assert_response :forbidden
      delete "#{BASE}/1"
      assert_response :forbidden
      assert_no_writes
    end
  end

  test "missing and foreign entries never reach a write" do
    sign_in
    with_rpms do
      post "#{BASE}/99/default"
      refute response.successful?
      delete "#{BASE}/99"
      refute response.successful?
      assert_no_writes
    end
  end

  test "unknown and non-clinic resources refuse reads and writes" do
    sign_in
    with_rpms(resources: [ RESOURCE.merge(id: 6, hospital_location_id: nil) ]) do
      [ 5, 6 ].each do |id|
        base = "/lakeraven-ehr/scheduling/clinics/#{id}/providers"
        get base
        assert_response :not_found
        post "#{base}/1/default"
        assert_response :not_found
        delete "#{base}/1"
        assert_response :not_found
      end
      assert_no_writes
    end
  end

  test "empty list is distinct from unavailable list and unavailable membership prevents writes" do
    sign_in
    with_rpms(reads: [ [] ]) do
      get BASE
      assert_response :success
      assert_match(/(no providers|no clinic providers|none)/i, response.body)
    end
    with_rpms(reads: [ nil, nil ]) do
      get BASE
      refute_match(/(no providers|no clinic providers|none)/i, response.body)
      assert_match(/(unavailable|unable|could not|error)/i, response.body)
      delete "#{BASE}/1"
      assert_no_writes
    end
  end

  test "unconfirmed outcomes and inconsistent readback are never reported as success" do
    sign_in
    [ nil, { success: false, error: "RAW BROKER SECRET" }, IOError.new("RAW BROKER SECRET"), { success: true } ].each do |outcome|
      [ :default, :remove ].each do |action|
        with_rpms(outcome: outcome, apply: false) do
          action == :default ? post("#{BASE}/2/default") : delete("#{BASE}/1")
          assert_unconfirmed
        end
      end
    end
  end

  test "failed or inconsistent readback cannot confirm a write" do
    sign_in
    [ nil, IOError.new("RAW BROKER SECRET"),
      PROVIDERS.map { |p| p.merge(default: true) } ].each do |readback|
      with_rpms(reads: [ PROVIDERS.map(&:dup), readback ]) do
        post "#{BASE}/2/default"
        assert_unconfirmed
      end
    end
    with_rpms(reads: [ PROVIDERS.map(&:dup), nil ]) do
      delete "#{BASE}/1"
      assert_unconfirmed
    end
  end

  test "a scheduler cannot see a resource without view rights" do
    sign_in("scheduling_user")
    with_rpms(resources: [ RESOURCE.merge(view: false) ]) do
      get BASE
      assert_response :not_found
      assert_no_writes
    end
  end

  test "write forms are protected by framework CSRF checks" do
    sign_in
    with_rpms do
      with_forgery_protection do
        post "#{BASE}/2/default"
        assert_response :unprocessable_content
        delete "#{BASE}/1"
        assert_response :unprocessable_content
        assert_no_writes
        get BASE
        assert_response :success
        assert_select "form[action='#{BASE}/2/default'] input[name='authenticity_token']"
        assert_select "form[action='#{BASE}/1'] input[name='authenticity_token']"
      end
    end
  end
end
