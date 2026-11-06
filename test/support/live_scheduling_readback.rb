# frozen_string_literal: true

# Live scheduling tests: drive the screens as the signed-on scheduler, and read
# back what RPMS then holds from FileMan (DDR GETS ENTRY DATA, DDR LISTER in the
# scheduler's CIAV VUECENTRIC context), so a test proves the write landed and
# not only that the app said so.
module LiveSchedulingReadback
  # The day view of the clinic resource of that name, from the scheduling home.
  def clinic_path(name)
    get "/lakeraven-ehr/scheduling"
    link = css_select("#resources a").find { |a| a.text == name }
    assert link, "#{name} is offered to the scheduler"
    link["href"].delete_suffix("/week")
  end

  def weekday_ahead(from: 7, spread: 7)
    day = Date.today + from + rand(spread)
    day += 1 while day.saturday? || day.sunday?
    day
  end

  # An open time ("HH:MM") on the clinic's day from 11:00, other than except.
  def open_time(clinic, day, except: nil)
    get clinic, params: { date: day.iso8601 }
    times = css_select("#open-times tr[data-time]").select do |tr|
      tr["data-time"] >= "11:00" && tr["data-time"] != except && tr.at_css("td[data-open]")["data-open"].to_i.positive?
    end
    assert times.any?, "#{clinic} has an open time on #{day}"
    times.sample["data-time"]
  end

  # Books MOUSE,MICKEY M (DFN 3) through the screen; returns the BSDX appointment id.
  def book(clinic, day, time, length: 15, note: "", dfn: 3)
    post "#{clinic}/appointments", params: { booking: { patient_dfn: dfn.to_s, start: "#{day.iso8601}T#{time}", length: length.to_s, note: note } }
    assert_response :redirect, "booking #{day} #{time}: #{flash[:alert]}"
    follow_redirect!
    row = css_select("#appointments tr[data-patient='#{dfn}']").find { |tr| tr.at_css("td").text.start_with?(time) && tr.at_css("td[data-status='booked']") }
    assert row, "the booking at #{time} shows on the clinic's day"
    row["data-appointment"].to_i
  end

  def wall(day, time) = Time.new(day.year, day.month, day.day, *time.split(":").map(&:to_i))

  # A FileMan date/time as an IENS piece: canonical, no trailing zeros.
  def fm(time) = RpmsRpc::FilemanDateParser.to_fileman(time).to_s.sub(/(\.\d*?)0+\z/, '\1').delete_suffix(".")

  # The patient's appointment at that time, PATIENT (#2.98): .01 CLINIC,
  # 3 STATUS, 14 CANCELLED BY USER, 16 CANCELLATION REASON, 17 CANCELLATION REMARKS.
  def patient_appointment(dfn, at)
    got = in_chart_context { RpmsRpc::DdrFileman.gets_entry(file: "2.98", iens: "#{fm(at)},#{dfn},", fields: ".01;3;14;16;17", flags: "IE") }
    assert got && !got[:error], "#2.98 #{fm(at)},#{dfn}: #{got.inspect}"
    got[:fields].transform_values { |v| v.merge(internal: v[:internal].to_s) }
  end

  # The appointments on the clinic at that time, HOSPITAL LOCATION (#44.003):
  # .01 PATIENT, 1 LENGTH OF APP'T, 3 OTHER (the note), 9 OVERBOOK.
  def clinic_appointments(clinic_ien, at)
    got = in_chart_context { RpmsRpc::DdrFileman.lister(file: "44.003", iens: ",#{fm(at)},#{clinic_ien},", fields: "@;.01I;1;3;9I") }
    assert got && !got[:error], "#44.003 ,#{fm(at)},#{clinic_ien},: #{got.inspect}"
    got[:entries].map do |e|
      patient, length, note, overbook = e[:pieces]
      { ien: e[:ien].to_i, patient: patient.to_s, length: length.to_s, note: note.to_s, overbook: overbook.to_s }
    end
  end

  def clinic_ien(name) = RpmsRpc::Scheduling.resources.find { |r| r[:name] == name }.fetch(:hospital_location_id)

  def in_chart_context(&) = RpmsRpc.client.with_context("CIAV VUECENTRIC", &)
end
