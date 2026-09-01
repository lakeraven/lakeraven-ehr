# frozen_string_literal: true

# Charting-a-visit steps (POV entry, progress note write/sign, and the
# end-to-end demo visit). Fake gateways are scenario-scoped and injected
# through the service constructors, mirroring FakeVitalGateway.

class FakePovGateway
  attr_reader :calls

  def initialize(return_value = { success: true, ien: 501, raw: "1^501" })
    @return_value = return_value
    @calls = []
  end

  def add(dfn, visit_ien, diagnosis_code, narrative:, modifiers: {})
    @calls << { dfn: dfn, visit_ien: visit_ien, diagnosis_code: diagnosis_code,
                narrative: narrative, modifiers: modifiers }
    @return_value
  end
end

class FakeProgressNoteGateway
  attr_reader :creates, :text_updates

  def initialize
    @creates = []
    @text_updates = []
  end

  def create(dfn, visit_ien, title_ien)
    @creates << { dfn: dfn, visit_ien: visit_ien, title_ien: title_ien }
    { success: true, ien: 7801, raw: "7801" }
  end

  def update_text(note_ien, text)
    @text_updates << { note_ien: note_ien, text: text }
    { success: true, raw: "1" }
  end
end

class FakeESignatureGateway
  attr_reader :validations, :sign_actions

  def initialize(valid: true)
    @valid = valid
    @validations = []
    @sign_actions = []
  end

  def validate(user_duz, signature_code)
    @validations << { user_duz: user_duz, signature_code: signature_code }
    { success: @valid, raw: @valid ? "1" : "0^Invalid code" }
  end

  def add(note_ien, user_duz, signature_code, action: :sign)
    @sign_actions << { note_ien: note_ien, user_duz: user_duz, action: action }
    { success: true, raw: "1" }
  end
end

Given("a demo visit with IEN {int}") do |visit_ien|
  @visit_ien = visit_ien
  @pov_gateway = FakePovGateway.new
  @note_gateway = FakeProgressNoteGateway.new
  @esig_gateway = FakeESignatureGateway.new
end

Given("no open visit") do
  @visit_ien = nil
end

Given("I am the authoring provider with DUZ {int}") do |duz|
  @author_duz = duz
end

Given("the POV gateway will fail") do
  @pov_gateway = FakePovGateway.new({ success: false, ien: nil, raw: "0^visit locked" })
end

Given("the signature code will fail validation") do
  @esig_gateway = FakeESignatureGateway.new(valid: false)
end

# --- POV -----------------------------------------------------------------

When("the provider records POV {string} with narrative {string}") do |code, narrative|
  @pov_result = Lakeraven::EHR::PovEntryService.new(
    dfn: @dfn,
    visit_ien: @visit_ien,
    diagnosis_code: code,
    narrative: narrative,
    gateway: @pov_gateway
  ).save
end

Then("the POV save should succeed") do
  assert @pov_result.success?, "POV save failed: #{@pov_result.error.inspect}"
end

Then("the POV save should fail with :{word}") do |reason|
  refute @pov_result.success?
  assert_equal reason.to_sym, @pov_result.error
end

Then("the POV gateway should receive diagnosis {string} for visit {int}") do |code, visit_ien|
  call = @pov_gateway.calls.last
  assert_equal code, call[:diagnosis_code]
  assert_equal visit_ien, call[:visit_ien]
end

# --- Progress note -------------------------------------------------------

def demo_note_service
  Lakeraven::EHR::ProgressNoteService.new(
    dfn: @dfn,
    visit_ien: @visit_ien,
    author_duz: @author_duz,
    gateway: @note_gateway,
    esignature_gateway: @esig_gateway
  )
end

When("the provider creates a progress note with title {int} and text:") do |title_ien, text|
  @note_result = demo_note_service.create(title_ien: title_ien, text: text)
end

When("the provider creates a progress note with no title") do
  @note_result = demo_note_service.create(title_ien: nil, text: "orphan text")
end

Given("a created progress note") do
  @note_result = demo_note_service.create(title_ien: 8927, text: "Demo note text.")
  assert @note_result.success?
end

Then("the note create should succeed with a note IEN") do
  assert @note_result.success?, "note create failed: #{@note_result.error.inspect}"
  refute_nil @note_result.note_ien
end

Then("the note create should fail with :{word}") do |reason|
  refute @note_result.success?
  assert_equal reason.to_sym, @note_result.error
end

Then("the note gateway should receive the note text") do
  update = @note_gateway.text_updates.last
  refute_nil update
  assert_equal({ success: true, raw: "1" }, @note_result.raw)
  refute update[:text].to_s.empty?
end

When("the provider signs the note with signature code {string}") do |code|
  @sign_result = demo_note_service.sign(
    note_ien: @note_result&.note_ien, signature_code: code
  )
end

Then("the note signing should succeed") do
  assert @sign_result.success?, "signing failed: #{@sign_result.error.inspect}"
end

Then("the note signing should fail with :{word}") do |reason|
  refute @sign_result.success?
  assert_equal reason.to_sym, @sign_result.error
end

Then("the e-signature gateway should receive a sign action for the note") do
  action = @esig_gateway.sign_actions.last
  assert_equal @note_result.note_ien, action[:note_ien]
  assert_equal :sign, action[:action]
end

Then("no sign action should reach the e-signature gateway") do
  assert_empty @esig_gateway.sign_actions
end

# --- Demo visit end-to-end ----------------------------------------------

When("the provider enters demo vitals TMP {string} F and BP {string} mmHg") do |tmp, bp|
  @demo_vital_gateway = FakeVitalGateway.new
  @demo_vitals_result = Lakeraven::EHR::VitalsEntryService.new(
    dfn: @dfn,
    visit_string: "492;3260904.11;A;#{@visit_ien}",
    measurements: [
      { abbreviation: "TMP", value: tmp, units: "F" },
      { abbreviation: "BP", value: bp, units: "mmHg" }
    ],
    provider_duz: @author_duz,
    gateway: @demo_vital_gateway
  ).save
end

Then("the demo vitals save should succeed") do
  assert @demo_vitals_result.success?
end

When("the provider closes the demo visit with reason {string} {string}") do |code, display|
  @demo_encounter = Lakeraven::EHR::Encounter.new(
    status: "in-progress", class_code: "AMB", patient_dfn: @dfn, ien: @visit_ien
  )
  @demo_encounter.close(reason_code: code, reason_display: display)
end

Then("the demo visit should be finished") do
  assert_equal "finished", @demo_encounter.status
end
