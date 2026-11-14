# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-15: a scheduling supervisor sees and changes a clinic's
# scheduling settings and letters. RPMS is stood in for at the gem boundary
# with the shapes a live rpms-ydb 7d0e827 build answered for DEMO PODIATRY
# (hospital location 11, resource 5); the live test proves the same against a
# container.
class SchedulingClinicSettingsTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  RESOURCES = [
    { id: 5, name: "DEMO PODIATRY", inactive: false, time_scale: 30, hospital_location_id: 11,
      view: true, overbook: false, modify_schedule: true, modify_appointments: true }
  ].freeze

  SETTINGS = {
    id: 11, name: "DEMO PODIATRY", abbreviation: "DPOD", institution: { id: 7819, name: "DEMO IHS CLINIC" },
    division: { id: 3, name: "DEMO IHS CLINIC" }, stop_code: { id: 58, name: "PODIATRY" }, length_minutes: 30,
    variable_length: false, display_begins: nil, increments_per_hour: 2, overbooks_per_day: 0, schedule_on_holidays: false,
    allowable_no_shows: 2, max_future_days: 90, prohibit_access: false, non_count: false, include_on_file_room_lists: false,
    meets_at_facility: true, no_show_letter: nil, pre_appointment_letter: { id: 1, name: "APPOINTMENT SLIP" },
    clinic_cancellation_letter: nil, appointment_cancellation_letter: nil, no_show_waiting_days: nil,
    create_visit_at_checkin: nil, visit_provider_required: nil, setup_entry: false, providers: []
  }.freeze

  LETTERS = [ { id: 1, name: "APPOINTMENT SLIP", type: :pre_appointment }, { id: 4, name: "MISSED YOU", type: :no_show } ].freeze
  STOPS = [ { id: 58, name: "PODIATRY", code: "65", inactive_date: nil }, { id: 13, name: "INTERNAL MEDICINE", code: "01", inactive_date: nil },
            { id: 99, name: "RETIRED STOP", code: "99", inactive_date: Date.new(2020, 1, 1) } ].freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_type: "user", user_name: "MANAGER,SYSTEM", security_keys: keys }
  end

  # Stands in for the gem; held is what RPMS holds, and update files into it.
  def with_rpms(held: SETTINGS, update: nil)
    @held = held.dup
    @updates = []
    log = @updates
    store = self
    update ||= ->(changes) { store.file(changes); { success: true } }
    stubs = {
      RpmsRpc::Scheduling.singleton_class => { resources: ->(*) { RESOURCES } },
      RpmsRpc::SchedulingSetup.singleton_class => {
        clinic_settings: ->(_id) { store.held },
        update_clinic_settings: ->(_id, changes) { log << changes; update.call(changes) },
        letters: ->(*) { LETTERS },
        clinic_stops: ->(*) { STOPS }
      }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  attr_reader :held

  def file(changes)
    changes.each do |key, value|
      @held[key] = Lakeraven::EHR::ClinicSettings::POINTERS.include?(key) && value ? { id: value, name: "#{key} #{value}" } : value
    end
  end

  def form_params(**changes)
    form = Lakeraven::EHR::ClinicSettings.from_rpms(SETTINGS)
    { settings: form.attributes.transform_values { |v| v.nil? ? "" : v.to_s }.merge(changes.transform_values(&:to_s)) }
  end

  test "S-SCH-15.1 the supervisor's change of length and future-booking days is all that is filed" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/5/settings", params: form_params(length_minutes: 60, max_future_days: 45)

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/5/settings"
      follow_redirect!
      assert_select "#settings-notice", text: /Settings saved/
      assert_select "dd[data-setting='length_minutes']", text: "60"
      assert_select "dd[data-setting='max_future_days']", text: "45"
    end

    assert_equal [ { length_minutes: 60, max_future_days: 45 } ], @updates
  end

  test "S-SCH-15.2 a length that does not fit the display increment is refused, named, and nothing is filed" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/5/settings", params: form_params(length_minutes: 20, allowable_no_shows: 1000)

      assert_response :unprocessable_content
      assert_select "#settings-errors", text: /Length of appointment.*multiple of the display increment \(30 minutes\)/m
      assert_select "#settings-errors", text: /Allowable consecutive no-shows/
    end

    assert_empty @updates
  end

  test "S-SCH-15.2 a setting FileMan refuses is named, and the page says the rest were saved" do
    sign_in("scheduling_supervisor")
    refusal = "The value '`4' for field NO SHOW LETTER in file HOSPITAL LOCATION is not valid."
    with_rpms(update: ->(_changes) { { success: false, refused: { no_show_letter: refusal } } }) do
      post "/lakeraven-ehr/scheduling/clinics/5/settings", params: form_params(no_show_letter: 4)

      assert_response :unprocessable_content
      assert_select "#settings-refused li[data-refused='no_show_letter']", text: /No-show letter: The value '`4'/
    end
  end

  test "S-SCH-15.3 create visit at check-in with a provider required and no default provider warns, and is saved" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/5/settings", params: form_params(create_visit_at_checkin: 1, visit_provider_required: 1)
      follow_redirect!

      assert_select "#settings-notice", text: /Settings saved/
      assert_select "#default-provider-warning", text: /no default provider/
    end

    assert_equal [ { create_visit_at_checkin: true, visit_provider_required: true } ], @updates
  end

  test "S-SCH-15.3 a clinic with a default provider is not warned" do
    sign_in("scheduling_supervisor")
    held = SETTINGS.merge(create_visit_at_checkin: true, visit_provider_required: true, setup_entry: true,
                          providers: [ { id: 1, duz: 206, name: "PROFILE,MD", default: true } ])
    with_rpms(held: held) do
      get "/lakeraven-ehr/scheduling/clinics/5/settings"

      assert_select "#default-provider-warning", count: 0
      assert_select "dd[data-setting='default_provider']", text: "PROFILE,MD"
    end
  end

  test "S-SCH-15.4 a scheduler without SDZSUP sees the settings and cannot change them" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5/settings"
      assert_response :success
      assert_select "dd[data-setting='length_minutes']", text: "30"
      assert_select "#edit-settings", count: 0

      get "/lakeraven-ehr/scheduling/clinics/5/settings/edit"
      assert_response :forbidden
      post "/lakeraven-ehr/scheduling/clinics/5/settings", params: form_params(length_minutes: 60)
      assert_response :forbidden
    end

    assert_empty @updates
  end

  test "S-SCH-15.5 each letter type shows the clinic's letter and offers only letters of that type" do
    sign_in("scheduling_supervisor")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5/settings"
      assert_select "dd[data-setting='pre_appointment_letter']", text: "APPOINTMENT SLIP"
      assert_select "dd[data-setting='no_show_letter']", text: "None"

      get "/lakeraven-ehr/scheduling/clinics/5/settings/edit"
      assert_select "select#settings_no_show_letter option", text: "MISSED YOU"
      assert_select "select#settings_no_show_letter option", text: "APPOINTMENT SLIP", count: 0
      assert_select "select#settings_pre_appointment_letter option[selected]", text: "APPOINTMENT SLIP"
      assert_select "select#settings_stop_code option", text: /RETIRED STOP/, count: 0
    end
  end
end
