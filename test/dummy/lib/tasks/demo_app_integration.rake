# frozen_string_literal: true

# Referral-loop demo (#993): an outside outreach app reads an open referral
# over FHIR, posts what it learned, a person confirms it, and the result lands
# back on the RPMS referral.
#
# PROTOTYPE on branch demo/app-integration, not for merge. The real build is
# the factory slices listed on #993 (#996, #997, #988, #989, #990, #1000, #992).
#
#   test/dummy/bin/demo-app-integration          # whole loop, no pauses
#   DEMO_PAUSE=1 test/dummy/bin/demo-app-integration   # Enter between steps
#
# Every step prints REAL or MOCK. REAL means the engine's own code answered
# (its token endpoint, FHIR controllers and gateways), reading the in-memory
# mock RPMS broker seeded with synthetic data, exactly as the chart demo does.
# MOCK means the step is not built yet and Demo::ReferralLoopMock stands in.
#
# SYNTHETIC DATA ONLY: the patient, referral, facility and app are invented.
namespace :demo do
  desc "Referral-loop demo (#993) on synthetic data: outside app -> FHIR -> review -> RPMS"
  task app_integration: :environment do
    unless Rails.env.development? || Rails.env.test?
      abort "demo:app_integration runs only in development or test (synthetic data, mock RPMS)."
    end

    require "rpms_rpc/mock_client"
    require Rails.root.join("lib/lakeraven_demo_seeds").to_s
    require Rails.root.join("lib/demo/outreach_app").to_s
    require Rails.root.join("lib/demo/referral_loop_mock").to_s

    DemoRun.new.call
  end
end

class DemoRun
  PATIENT_DFN = 1
  REFERRAL = {
    ien: "4101", patient_dfn: PATIENT_DFN, referral_number: "DEMO-2026-0042",
    status: "A1", purpose: "Behavioral health intake, outside counseling practice",
    facility: "Example Counseling Partners (synthetic)", date: Date.current - 9
  }.freeze
  REVIEWER = "DEMO,COORDINATOR (synthetic PRC coordinator)"

  def call
    banner
    seed_rpms
    app = Demo::OutreachApp.new(Rails.application)
    stub_jwks_for(app)
    loop_mock = Demo::ReferralLoopMock.new

    step 1, "A site admin registers the outreach app", :real,
      "Doorkeeper application bound to the site's organization, with the app's JWKS URL." do
      registered = app.register!
      say "client_id #{registered.uid}, scopes: #{registered.scopes}"
      say "MOCK detail: the app's JWKS URL is answered in-process (no public host for the demo)."
    end

    step 2, "The app gets a SMART Backend Services token", :real,
      "POST /oauth/token, client_credentials with a signed JWT (RS384)." do
      status, body = app.request_token!(scope: "system/Patient.read system/ServiceRequest.read")
      check!(status == 200, "token endpoint answered #{status}: #{body}")
      say "HTTP #{status}: token_type #{body['token_type']}, scope \"#{body['scope']}\", expires_in #{body['expires_in']}s"
    end

    service_request = nil
    step 3, "The app reads the patient and the open referral over FHIR", :real,
      "GET /Patient/1 and GET /ServiceRequest?patient=1, served by the engine from the mock RPMS broker." do
      status, patient = app.get("Patient/#{PATIENT_DFN}")
      check!(status == 200, "Patient read answered #{status}: #{patient}")
      name = Array(patient["name"]).first || {}
      say "Patient/#{patient['id']}: #{Array(name['given']).join(' ')} #{name['family']}, born #{patient['birthDate']}"

      status, bundle = app.get("ServiceRequest", patient: PATIENT_DFN.to_s)
      check!(status == 200, "ServiceRequest search answered #{status}: #{bundle}")
      service_request = Array(bundle["entry"]).map { |e| e["resource"] }.first
      check!(service_request, "no ServiceRequest came back for the seeded referral")
      say "ServiceRequest/#{service_request['id']}: #{service_request.dig('code', 'text')}, status #{service_request['status']}, authored #{service_request['authoredOn']}"
      say "Live-RPMS caveat: against a real broker this read answers 503 until #996 (service-account token) lands."
    end

    communication = build_communication(service_request)
    held = nil
    step 4, "The app calls the patient and posts the outcome as a FHIR Communication", :mock,
      "Not built: POST /Communication is #988. Held for review in the demo's stand-in store." do
      say "(The phone call itself is outside the EHR; the app reports: reached, booked, transport barrier.)"
      status, _body = app.post_fhir("Communication", communication)
      say "Real engine answer to POST /Communication today: HTTP #{status} (route not built, #988)."
      held = loop_mock.hold(communication, ai_generated: true)
      say "MOCK: held as #{held.id}, status #{held.status}. Nothing has reached RPMS or Corvid."
      say JSON.pretty_generate(communication).lines.first(14).join.rstrip
      say "  ..."
    end

    step 5, "A referral coordinator reviews and confirms it", :mock,
      "Not built: the review queue is #989 (correct-then-confirm is #1000)." do
      loop_mock.pending.each do |item|
        outcome = loop_mock.outcome_of(item.communication)
        label = item.ai_generated ? "[AI-generated] " : ""
        say "Queue: #{label}#{item.id} for Patient/#{PATIENT_DFN}, #{REFERRAL[:referral_number]}: " \
            "reached=#{outcome[:reached]}, appointment #{outcome[:appointment_on]}, barriers: #{outcome[:barriers]}"
      end
      loop_mock.confirm(held, reviewer: REVIEWER)
      say "MOCK: confirmed by #{held.reviewed_by} at #{held.reviewed_at.iso8601}. A rejected result would stop here."
    end

    step 6, "The confirmed result is written back to the RPMS referral", :mock,
      "Not built: write-back is #990 through the outbox (#997), on BMC RCIS calls rpms-rpc#722 must prove live." do
      updated = loop_mock.write_back_to_rpms(held, REFERRAL)
      loop_mock.rpms_writes.each { |w| say "MOCK RPMS write, referral #{REFERRAL[:referral_number]}: #{w[:field]} = #{w[:value]}" }
      say "MOCK broker referral row now: appointment #{updated[:appointment_date]}"
    end

    step 7, "Corvid records the confirmed follow-up", :not_built,
      "Not built: #998, waiting on lakeraven/corvid#815 and the Corvid freeze. Shown as the payload it would send." do
      say JSON.pretty_generate(loop_mock.corvid_payload(held, REFERRAL))
    end

    step 8, "Read-back: the referral as RPMS now holds it", :real,
      "Real reads (engine FHIR, then BMC SEARCH REFERRAL) of the row step 6 mock-wrote." do
      status, bundle = app.get("ServiceRequest", patient: PATIENT_DFN.to_s)
      check!(status == 200, "ServiceRequest read-back answered #{status}")
      sr = Array(bundle["entry"]).map { |e| e["resource"] }.first
      say "FHIR ServiceRequest/#{sr['id']}: status #{sr['status']} (the FHIR mapping does not carry the appointment yet)"
      row = RpmsRpc::Referral.for_patient(PATIENT_DFN.to_s).first
      say "RPMS referral #{row[:referral_number]} (BMC SEARCH REFERRAL): appointment #{row[:appointment_date]}"
      say "  scheduling notes: #{row[:scheduling_notes]}"
    end

    summary
  end

  private

  def banner
    puts <<~TEXT

      Referral loop demo (#993): an outside outreach app closes a referral with RPMS
      SYNTHETIC DATA ONLY. RPMS is the in-memory mock broker; no PHI, no live system.
      Prototype branch demo/app-integration, not for merge.
    TEXT
  end

  # The chart demo's synthetic seed (patient Anderson, Alice, DFN 1), plus one
  # approved outside referral for the outreach app to work.
  def seed_rpms
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    RpmsRpc.client.seed_keyed_collection(:referral_search, PATIENT_DFN.to_s, [ REFERRAL.dup ])
  end

  # The app publishes its keys at JWKS_URI. The demo has no public host, so
  # that one URI answers with the app's keys; every other URI still goes
  # through the real fetch.
  def stub_jwks_for(app)
    jwks = app.published_jwks
    real = Lakeraven::EHR::ClientJwks.method(:fetch)
    Lakeraven::EHR::ClientJwks.define_singleton_method(:fetch) do |uri|
      uri == Demo::OutreachApp::JWKS_URI ? jwks : real.call(uri)
    end
  end

  # What an outreach app would post (#988): about the referral, subject the
  # patient, sender the app's Device, structured fields plus a short summary.
  def build_communication(service_request)
    base = "https://lakeraven.example.test/fhir/StructureDefinition/outreach"
    {
      resourceType: "Communication",
      status: "completed",
      about: [ { reference: "ServiceRequest/#{service_request['id']}" } ],
      subject: { reference: "Patient/#{PATIENT_DFN}" },
      sender: { reference: "Device/#{Demo::OutreachApp::CLIENT_ID}", display: Demo::OutreachApp::NAME },
      sent: Time.current.iso8601,
      extension: [
        { url: "#{base}#reached", valueBoolean: true },
        { url: "#{base}#appointmentDate", valueDate: (Date.current + 6).iso8601 },
        { url: "#{base}#barriers", valueString: "needs a ride; clinic van offered" }
      ],
      payload: [ { contentString: "Patient reached by phone and booked the intake. Asked for transport." } ]
    }
  end

  LABELS = { real: "REAL", mock: "MOCK", not_built: "NOT BUILT" }.freeze

  def step(number, title, kind, detail)
    @results ||= []
    puts
    puts "[#{number}] #{title}  ..........  #{LABELS.fetch(kind)}"
    puts "    #{detail}"
    yield
    @results << [ number, title, kind, :ok ]
    pause
  rescue DemoFailure => e
    @results << [ number, title, kind, :failed ]
    puts "    FAILED: #{e.message}"
    summary
    exit 1
  end

  def say(text)
    text.to_s.each_line { |l| puts "    #{l.rstrip}" }
  end

  def pause
    return unless ENV["DEMO_PAUSE"] == "1" && $stdin.tty?

    print "    (Enter for the next step) "
    $stdin.gets
  end

  class DemoFailure < StandardError; end

  def check!(condition, message)
    raise DemoFailure, message unless condition
  end

  def summary
    puts
    puts "Summary"
    @results.to_a.each do |number, title, kind, state|
      puts format("  %-3s %-9s %-6s %s", "#{number}.", LABELS.fetch(kind), state == :ok ? "ok" : "FAILED", title)
    end
    puts
  end
end
