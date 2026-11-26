# frozen_string_literal: true

require "nokogiri"
require "uri"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/pov"
require "rpms_rpc/api/problem"
require "rpms_rpc/fileman_date_parser"

# Add the diagnosis a provider found as a problem, and as today's purpose of
# visit (features/problem_list/add_diagnosis_as_problem.feature; rpms-ux
# S-VIS-02.2, S-VIS-02.3). The scenarios sign on through the app's own login,
# so the session holds the keys RPMS reports, and walk the pages a browser
# would. The checks after a save read RPMS directly, through rpms-rpc, as the
# run's persona.
module ProblemEntrySteps
  MOUNT = "/lakeraven-ehr"
  # The patients this feature owns: their problem lists and today's visits
  # are written here and nowhere else in the suite.
  OWNED_PATIENTS = %w[990022 990026].freeze
  # The concepts the scenarios file, removed from the owned patients' lists
  # before and after each scenario.
  CONCEPTS = %w[370143000 21897009 421986006 65363002].freeze
  CLINIC = "DEMO BEHAVIORAL HEALTH"
  # BSTS concept numbers, read from the pinned build's search.
  DTS_IDS = { "370143000" => "370143" }.freeze


  def doc = Nokogiri::HTML(last_response.body)

  def csrf = doc.at_css("meta[name='csrf-token']")&.[]("content")

  def follow_all! = (follow_redirect! while last_response.redirect?)

  def sign_on_to_app!(access, verify)
    Lakeraven::EHR::LoginThrottle.reset!
    get "#{MOUNT}/login"
    post "#{MOUNT}/login", { username: access, password: verify, authenticity_token: csrf }
    assert last_response.redirect?, "sign-on as #{access}: #{last_response.status} #{doc.at_css("[role='alert']")&.text.to_s.squish}"
    follow_all!
  end

  def open_record!(dfn)
    get "#{MOUNT}/dashboard"
    post "#{MOUNT}/patients/#{dfn}/context", { authenticity_token: csrf }
    follow_all!
  end

  # The fields of the problem form as a browser would send them, with
  # overrides: the hidden concept, the status selected, the side chosen, the
  # purpose-of-visit box and the visit chosen.
  def problem_form_fields(overrides = {})
    form = doc.at_css("#problem-form")
    flunk "no problem form on the page: #{doc.at_css('main')&.text.to_s.squish[0, 400]}" unless form
    fields = { "authenticity_token" => csrf, "dts_id" => form.at_css("input[name=dts_id]")["value"] }
    fields["status"] = form.at_css("select[name=status] option[selected]")&.[]("value") || form.at_css("select[name=status] option")["value"]
    box = form.at_css("input#problem_pov")
    fields["pov"] = box && box["checked"] ? "1" : "0"
    chosen = form.at_css("input[name=visit_ien][checked]")
    fields["visit_ien"] = chosen["value"] if chosen
    fields.merge(overrides.transform_keys(&:to_s)).compact
  end

  def problem_form_path = URI(doc.at_css("#problem-form")["action"]).path

  # The INSTITUTION and HOSPITAL LOCATION the build's own entries use.
  def clinic_ien
    @clinic_ien ||= begin
      page = RpmsRpc::DdrFileman.lister(file: "44", fields: ".01", flags: "IP", max: "200")
      row = page[:entries].find { |e| e[:pieces].first == CLINIC }
      flunk "HOSPITAL LOCATION #{CLINIC} is not on file: is this the pinned demo image?" unless row
      row[:ien].to_s
    end
  end

  def todays_open_visits(dfn)
    today = Lakeraven::EHR::SiteTime.today
    RpmsRpc::Encounter.visits(dfn).select do |v|
      v[:locked] == false && v[:datetime].respond_to?(:to_date) && v[:datetime].to_date == today
    end
  end

  # A visit today at the clinic, made through RPMS as setup when the patient
  # has none (the visit a check-in would file).
  def open_visit_today!(dfn)
    found = todays_open_visits(dfn).find { |v| v[:location_ien].to_s == clinic_ien }
    return found[:visit_ien].to_s if found

    now = Lakeraven::EHR::SiteTime.now
    at = RpmsRpc::FilemanDateParser.format_datetime(Time.new(now.year, now.month, now.day, now.hour, now.min) - 600)
    made = RpmsRpc::Encounter.create(dfn, location_ien: clinic_ien, datetime: at, service_category: "A", create: 1)
    flunk "Encounter.create for #{dfn} answered #{made.inspect}" unless made[:success]
    made[:visit_ien].to_s
  end

  def problems_for(dfn, concept) = RpmsRpc::Problem.duplicate_check(dfn, concept)[:on_file]

  # Every purpose of visit on the patient's visits filed against the problem.
  def diagnoses_for(dfn, problem_ien)
    RpmsRpc::Encounter.visits(dfn).flat_map { |v| RpmsRpc::Pov.for_visit(v[:visit_ien]) }
                      .select { |row| row[:problem_ien].to_s == problem_ien.to_s }
  end

  # Removes what this feature files on its patients: each purpose of visit
  # filed against one of its concepts' problems, then the problem. Each
  # removal is read back by rpms-rpc; one that fails stops the run.
  def remove_filed!
    OWNED_PATIENTS.each do |dfn|
      CONCEPTS.each do |concept|
        problems_for(dfn, concept).each do |problem|
          diagnoses_for(dfn, problem[:ien]).each do |row|
            gone = RpmsRpc::Pov.delete(dfn, row[:ien], problem_ien: problem[:ien])
            flunk "V POV #{row[:ien]} on #{dfn} could not be removed: #{gone.inspect}" unless gone[:success]
          end
          gone = RpmsRpc::Problem.delete(dfn, problem[:ien], reason: "Entered in error")
          flunk "PROBLEM #{problem[:ien]} on #{dfn} could not be removed: #{gone.inspect}" unless gone[:success]
        end
      end
    end
  end

  def disposable_local_rpms?
    host = Lakeraven::EHR::Engine.rpms_settings[:host].to_s
    LIVE_RPMS && !LIVE_STACK_BINDING && %w[127.0.0.1 localhost ::1].include?(host)
  end
end
World(ProblemEntrySteps)

# The scenarios file problems and visit diagnoses. The stand-in holds no
# problem list, and a shared stack must not be written to, so they run only
# against a disposable RPMS on this machine (cucumber --profile live).
Before("@problem_entry and @live") do
  skip_this_scenario("not run: writes; needs a disposable RPMS on this machine (cucumber --profile live)") unless disposable_local_rpms?
  @forgery_was = ActionController::Base.allow_forgery_protection
  ActionController::Base.allow_forgery_protection = true
  remove_filed!
end

After("@problem_entry and @live") do
  next unless disposable_local_rpms?

  ActionController::Base.allow_forgery_protection = @forgery_was unless @forgery_was.nil?
  LiveRpmsSession.sign_on!
  remove_filed!
end

Given("patient {string}, whom this feature owns, has an open visit today") do |dfn|
  @dfn = dfn
  @visit_ien = open_visit_today!(dfn)
end

Given("patient {string}, whom this feature owns, has no open visit today") do |dfn|
  @dfn = dfn
  open = todays_open_visits(dfn)
  assert_empty open, "patient #{dfn} must have no open visit today on this container: #{open.map { |v| v[:visit_ien] }}"
end

Given("the patient's problem list holds SNOMED CT {string}, filed through RPMS") do |concept|
  entry = RpmsRpc::Problem.duplicate_check(@dfn, concept)[:new_entry]
  location = RpmsRpc.client.division&.dig(:ien)
  filed = RpmsRpc::Problem.add(@dfn, { snomed_ct: concept, descriptive_ct: entry[:description_id], icd_code: entry[:icd_codes].first,
                                       description: entry[:narrative], location_ien: location })
  assert filed[:success], "setup Problem.add answered #{filed.inspect}"
end

Given("the provider has signed on as {string} and opened the record of patient {string}") do |access, dfn|
  @signed_on_as_scenario_user = true
  sign_on_to_app!(access, "#{access}!!")
  open_record!(dfn)
end

Given("the front desk clerk has signed on as {string} and opened the record of patient {string}") do |access, dfn|
  @signed_on_as_scenario_user = true
  sign_on_to_app!(access, "#{access}!!")
  open_record!(dfn)
end

When("the provider finds {string} and opens the SNOMED CT concept {string}") do |term, concept|
  get "#{ProblemEntrySteps::MOUNT}/diagnosis_search", { q: term }
  link = doc.at_css("#diagnosis-search-results tr[data-concept-id='#{concept}'] th a")
  refute_nil link, "no #{concept} among: #{doc.css('#diagnosis-search-results td[data-snomed]').map(&:text)}"
  @concept = concept
  @dts_id = link["href"][%r{/concepts/(\d+)}, 1]
  get link["href"]
  assert_equal 200, last_response.status
end

When("the provider chooses {string}") do |label|
  link = doc.at_css("a#diagnosis-add-problem")
  refute_nil link, "no #{label.inspect} on the concept page: #{doc.at_css('main')&.text.to_s.squish[0, 300]}"
  assert_equal label, link.text.strip
  get link["href"]
  assert_equal 200, last_response.status, doc.at_css("main")&.text.to_s.squish[0, 400]
end

Then("the page offers today's open visit with {string} ticked") do |label|
  assert_equal label, doc.at_css("label[for=problem_pov]")&.text&.strip
  assert doc.at_css("input#problem_pov[checked]"), "the box is not ticked"
  refute_nil doc.at_css("input[name=visit_ien][value='#{@visit_ien}']"), "today's visit #{@visit_ien} is not offered"
end

When("the provider saves") do
  post problem_form_path, problem_form_fields(visit_ien: @visit_ien)
  follow_all!
end

When("the provider clears {string} and saves") do |_label|
  post problem_form_path, problem_form_fields(pov: "0")
  follow_all!
end

When("the provider chooses the side {string}, clears {string} and saves") do |side, _label|
  post problem_form_path, problem_form_fields(pov: "0", laterality: side)
  follow_all!
end

When("the provider sends the form anyway") do
  post "#{ProblemEntrySteps::MOUNT}/patients/#{@dfn}/problems", { authenticity_token: csrf, dts_id: @dts_id, status: "Episodic", pov: "0" }
end

When("the provider sends the form anyway, as today's purpose of visit") do
  post problem_form_path, problem_form_fields(pov: "1", visit_ien: "1")
end

# The clerk is not offered the form; this is the request a browser would send.
When("the front desk clerk sends the form to add the SNOMED CT concept {string}") do |concept|
  @concept = concept
  post "#{ProblemEntrySteps::MOUNT}/patients/#{@dfn}/problems", { authenticity_token: csrf, dts_id: ProblemEntrySteps::DTS_IDS.fetch(concept), status: "Episodic",
                                               pov: "1", visit_ien: @visit_ien }
end

Then("the page shows the problem RPMS stored, SNOMED CT {string} with ICD-10-CM {string}") do |concept, icd|
  assert_equal 200, last_response.status, doc.at_css("main")&.text.to_s.squish[0, 500]
  stored = doc.at_css("#problem-stored")
  refute_nil stored, "no stored problem shown: #{doc.at_css('main')&.text.to_s.squish[0, 500]}"
  assert_equal concept, stored.at_css("dd[data-snomed]").text.strip
  assert_equal icd, stored.at_css("dd[data-icd]").text.strip
  @problem_ien = stored["data-problem-ien"]
end

Then("the page shows the purpose of visit RPMS stored on today's visit, ICD-10-CM {string}") do |icd|
  rows = doc.css("#problem-visit-diagnoses tr[data-pov-ien]")
  refute_empty rows, "no purpose of visit shown: #{doc.at_css('#problem-visit-diagnoses')&.text.to_s.squish}"
  assert_includes rows.map { |r| r.at_css("td[data-icd]").text.strip }, icd
end

Then("the page shows the side {string}") do |side|
  assert_equal side, doc.at_css("#problem-stored dd[data-laterality]")&.text&.strip
end

Then("RPMS's problem list for the patient holds SNOMED CT {string} once") do |concept|
  held = problems_for(@dfn, concept)
  assert_equal 1, held.size, "PROBLEM entries for #{concept} on #{@dfn}: #{held.map { |p| p[:ien] }}"
  assert_equal @problem_ien, held.first[:ien].to_s if @problem_ien
end

Then("RPMS's problem list for the patient does not hold SNOMED CT {string}") do |concept|
  assert_empty problems_for(@dfn, concept), "#{concept} is on #{@dfn}'s problem list"
end

Then("RPMS holds the purpose of visit on today's visit, filed against that problem") do
  rows = RpmsRpc::Pov.for_visit(@visit_ien).select { |row| row[:problem_ien].to_s == @problem_ien }
  refute_empty rows, "BGOVPOV GET on visit #{@visit_ien} lists no diagnosis filed against PROBLEM #{@problem_ien}"
end

Then("RPMS holds the purpose of visit on today's visit, filed against that problem, with ICD-10-CM {string}") do |codes|
  rows = RpmsRpc::Pov.for_visit(@visit_ien).select { |row| row[:problem_ien].to_s == @problem_ien }
  assert_equal codes.split(", ").sort, rows.map { |row| row[:icd_code] }.sort
end

Then("RPMS holds no purpose of visit on today's visit for that problem") do
  rows = RpmsRpc::Pov.for_visit(@visit_ien).select { |row| row[:problem_ien].to_s == @problem_ien }
  assert_empty rows, "visit #{@visit_ien} holds #{rows.map { |r| r[:ien] }} for PROBLEM #{@problem_ien}"
  assert_nil doc.at_css("#problem-visit-diagnoses"), "the page shows a purpose of visit"
end

Then("the patient's chart lists the problem {string}") do |text|
  get "#{ProblemEntrySteps::MOUNT}/patients/#{@dfn}"
  assert_equal 200, last_response.status
  listed = doc.css("#chart-problems-table tbody tr").map { |tr| tr.text.squish }
  assert listed.any? { |row| row.include?(text) }, "the chart's problem list: #{listed}"
end

Then("the page asks for the side: {string}, {string} or {string}") do |*sides|
  assert_equal sides, doc.css("#problem-laterality label").map { |l| l.text.strip }
end

Then("the page says {string} and nothing was saved") do |message|
  assert_equal 422, last_response.status
  assert_includes doc.at_css("#problem-refusal")&.text.to_s.squish, message
  assert_empty problems_for(@dfn, @concept), "#{@concept} is on #{@dfn}'s problem list"
end

Then("the page says the concept is on the patient's problem list already, and offers no save") do
  refute_nil doc.at_css("#problem-on-file li[data-problem-ien]"), "the problem on file is not named"
  assert_nil doc.at_css("#problem-form")
end

Then("the page says {string} with status {int}") do |message, status|
  assert_equal status, last_response.status, doc.at_css("main")&.text.to_s.squish[0, 400]
  assert_includes doc.at_css("#problem-refusal")&.text.to_s.squish, message
end

Then("the page says the patient has no open visit today, and offers no purpose of visit") do
  refute_nil doc.at_css("#problem-no-open-visit")
  assert_nil doc.at_css("input#problem_pov")
end

Then("the page says the account does not hold the security key, with status {int}") do |status|
  assert_equal status, last_response.status, last_response.body[0, 400]
  assert_includes doc.text.squish, "doesn't hold the security key this screen needs"
end
