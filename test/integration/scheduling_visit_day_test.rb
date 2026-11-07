# frozen_string_literal: true

require "test_helper"

# The patient's day after booking (rpms-ux S-SCH-03.9, S-SCH-07, S-SCH-08):
# undo a check-in, check out and undo it, mark a no-show and undo it. RPMS is
# stood in for at the gem boundary. On a built image BSDX refuses only a
# check-out of an appointment not checked in and an undo of one not checked
# out; undoing a check-in that is not there and every no-show answer success,
# so those states are checked here and tested here.
class SchedulingVisitDayTest < ActionDispatch::IntegrationTest
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: true, modify_schedule: true, modify_appointments: true }.freeze

  # Midday, so "an hour ago" is still today whenever CI runs.
  setup { travel_to Time.now.change(hour: 12) }

  def today = Date.today
  def ago(minutes) = Time.now - (minutes * 60)

  def appointment(**state)
    { id: 8, start_time: ago(60), end_time: ago(45), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil, checkout_time: nil }.merge(state)
  end

  def checked_in = appointment(checkin_time: ago(50))

  def sign_in = post("/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" })

  # listed: the day as RPMS lists it; after: as it lists it once a write was sent.
  # replies: what each write answers.
  def with_rpms(listed: [ appointment ], after: listed, replies: {}, create_visit: "YES")
    log = (@writes ||= [])
    answer = ->(name, *args) { log << [ name, *args ]; replies.fetch(name, { success: true }).then { |r| r.respond_to?(:call) ? r.call : r } }
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        slot_schedule: ->(**) { [] },
        appointments: ->(**) { log.empty? ? listed : after },
        clinic_setup: ->(*) { [ { location_ien: 3, location: "DEMO IHS CLINIC", create_visit: create_visit, visit_provider_required: "NO" } ] },
        cancel_checkin: ->(id) { answer.call(:cancel_checkin, id) },
        checkout_appointment: ->(id, **kw) { answer.call(:checkout_appointment, id, kw) },
        cancel_checkout: ->(id) { answer.call(:cancel_checkout, id) },
        mark_no_show: ->(id, no_show: true) { answer.call(:mark_no_show, id, no_show) }
      }
    }.merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def writes = @writes || []
  def base = "/lakeraven-ehr/scheduling/clinics/2/appointments/8"
  def day = "/lakeraven-ehr/scheduling/clinics/2?date=#{today.iso8601}"
  def at_param(time) = time.strftime("%Y-%m-%dT%H:%M")

  test "S-SCH-03.9 the scheduler undoes a check-in, and is told the visit stays" do
    sign_in
    with_rpms(listed: [ checked_in ], after: [ appointment ]) do
      post "#{base}/checkin/undo", params: { date: today.iso8601 }
    end

    assert_redirected_to day
    assert_equal [ [ :cancel_checkin, 8 ] ], writes
    assert_match(/Undid the check-in of MOUSE,MICKEY M/, flash[:notice])
    assert_match(/visit made at check-in stays/, flash[:notice])
  end

  test "S-SCH-03.9 only a checked-in appointment, not yet checked out, has its check-in undone" do
    sign_in
    [ appointment, appointment(checkin_time: ago(50), checkout_time: ago(20)), appointment(cancelled: true) ].each do |state|
      with_rpms(listed: [ state ]) do
        post "#{base}/checkin/undo", params: { date: today.iso8601 }
        assert_response :conflict
      end
    end
    assert_empty writes
  end

  test "S-SCH-07.1 a checked-in patient is checked out with the time they left" do
    sign_in
    left = ago(10)
    with_rpms(listed: [ checked_in ]) do
      get "#{base}/checkout", params: { date: today.iso8601 }
      assert_select "#checkout-form input[type='datetime-local'][name='checkout[at]']"

      post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(left) } }
    end

    assert_redirected_to day
    name, id, kw = writes.sole
    assert_equal [ :checkout_appointment, 8, 3 ], [ name, id, kw[:patient_dfn] ]
    assert_equal at_param(left), at_param(kw[:checkout_time])
    assert_match(/Checked out MOUSE,MICKEY M/, flash[:notice])
  end

  test "S-SCH-07.2 an appointment not checked in, already checked out or cancelled is not checked out" do
    sign_in
    [ appointment, appointment(checkin_time: ago(50), checkout_time: ago(20)), appointment(cancelled: true) ].each do |state|
      with_rpms(listed: [ state ]) do
        post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(ago(5)) } }
        assert_response :conflict
      end
    end
    assert_empty writes
  end

  test "S-SCH-07.3 a check-out before the appointment's day or before the check-in is refused, and nothing is filed" do
    sign_in
    with_rpms(listed: [ checked_in ]) do
      post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(ago(60 * 24 * 2)) } }
      assert_select "#checkout-errors li", text: /cannot be before the appointment's day/

      post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(ago(50)) } }
      assert_select "#checkout-errors li", text: /at least a minute after the check-in/
    end
    assert_empty writes
  end

  test "S-SCH-07.4 a check-out more than five minutes ahead is refused; a few minutes ahead is filed as now" do
    sign_in
    with_rpms(listed: [ checked_in ]) do
      post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(Time.now + 600) } }
      assert_select "#checkout-errors li", text: /more than 5 minutes from now/
      assert_empty writes

      post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(Time.now + 180) } }
      assert_response :redirect
    end
    assert_operator writes.sole[2][:checkout_time], :<=, Time.now
  end

  test "S-SCH-07.3 RPMS's refusal of a check-out is shown in its words" do
    sign_in
    reason = "Check Out time must be at least 1 minute after the Check In time of Nov 03, 2026 09:10."
    with_rpms(listed: [ checked_in ], replies: { checkout_appointment: { success: false, error: reason } }) do
      post "#{base}/checkout", params: { date: today.iso8601, checkout: { at: at_param(ago(5)) } }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /at least 1 minute after the Check In time/
  end

  test "S-SCH-07.6 the scheduler undoes a check-out, and only of a checked-out appointment" do
    sign_in
    with_rpms(listed: [ checked_in ]) do
      post "#{base}/checkout/undo", params: { date: today.iso8601 }
      assert_response :conflict
    end
    with_rpms(listed: [ appointment(checkin_time: ago(50), checkout_time: ago(20)) ]) do
      post "#{base}/checkout/undo", params: { date: today.iso8601 }
    end

    assert_redirected_to day
    assert_equal [ [ :cancel_checkout, 8 ] ], writes
    assert_match(/checked in again/, flash[:notice])
  end

  test "S-SCH-08.1 an appointment whose time has passed with no check-in is marked a no-show" do
    sign_in
    with_rpms do
      post "#{base}/no_show", params: { date: today.iso8601 }
    end

    assert_redirected_to day
    assert_equal [ [ :mark_no_show, 8, true ] ], writes
    assert_match(/a no-show/, flash[:notice])
  end

  test "S-SCH-08.2 an appointment not yet due, checked in, cancelled or a no-show is not marked a no-show" do
    sign_in
    later = appointment(start_time: Time.now + 3600, end_time: Time.now + 4500)
    [ later, checked_in, appointment(cancelled: true), appointment(no_show: true) ].each do |state|
      with_rpms(listed: [ state ]) do
        post "#{base}/no_show", params: { date: today.iso8601 }
        assert_response :conflict
      end
    end
    assert_empty writes
  end

  test "S-SCH-08.4 the scheduler undoes a no-show, and only of a no-show" do
    sign_in
    with_rpms do
      post "#{base}/no_show/undo", params: { date: today.iso8601 }
      assert_response :conflict
    end
    with_rpms(listed: [ appointment(no_show: true) ]) do
      post "#{base}/no_show/undo", params: { date: today.iso8601 }
    end

    assert_equal [ [ :mark_no_show, 8, false ] ], writes
    assert_match(/booked again/, flash[:notice])
  end

  test "a change RPMS gave no answer for is reported done when the appointment shows it" do
    sign_in
    with_rpms(listed: [ appointment ], after: [ appointment(no_show: true) ], replies: { mark_no_show: -> { raise IOError } }) do
      post "#{base}/no_show", params: { date: today.iso8601 }
    end

    assert_match(/a no-show/, flash[:notice])
    with_rpms(listed: [ appointment ], replies: { mark_no_show: nil }) do
      post "#{base}/no_show", params: { date: today.iso8601 }
    end
    assert_match(/did not confirm/, flash[:alert])
  end

  test "S-SCH-03.9, 07.1 and 08.1 the clinic's day offers each next step on the appointment, with its status in words" do
    sign_in
    rows = [ appointment(id: 1), appointment(id: 2, checkin_time: ago(50)), appointment(id: 3, checkin_time: ago(50), checkout_time: ago(20)),
             appointment(id: 4, no_show: true), appointment(id: 5, cancelled: true) ]
    with_rpms(listed: rows) do
      get day
    end

    actions = ->(id) { css_select("tr[data-appointment='#{id}'] [data-actions] a, tr[data-appointment='#{id}'] [data-actions] button").map { |e| e.text.strip } }
    assert_equal [ "Check in", "No-show", "Cancel", "Move", "Change details" ], actions.(1)
    assert_equal [ "Check out", "Undo check-in" ], actions.(2)
    assert_equal [ "Undo check-out" ], actions.(3)
    assert_equal [ "Undo no-show" ], actions.(4)
    assert_empty actions.(5)
    assert_select "tr[data-appointment='3'] td[data-status='checked-out']", text: /Checked out \d\d:\d\d/
    assert_select "tr[data-appointment='4'] td[data-status='no-show']", text: "No-show"
  end
end
