# frozen_string_literal: true

require "test_helper"

# The front desk's shared view pieces (docs/DESIGN-SYSTEM.md): each renders
# accessible HTML a screen reader and a keyboard can use, so a new screen gets
# that by calling the piece, not by remembering it.
class Lakeraven::EHR::ComponentsHelperTest < ActionView::TestCase
  include Lakeraven::EHR::ApplicationHelper

  FakeForm = Struct.new(:errors)

  # Assert on what the helper returned, not on the test view's buffer (the
  # partials a helper renders also append to it). Wrapped, so a selector can
  # match the fragment's own top element.
  def document_root_element = Nokogiri::HTML5.fragment("<div>#{@fragment}</div>")

  test "page_title ends with the configured product name" do
    page_title "Book", "Dental"
    assert_equal "Book | Dental | Lakeraven EHR", content_for(:title)
  end

  test "the product name in the chrome is one setting" do
    Lakeraven::EHR.configuration.product_name = "Front desk"
    page_title "Scheduling"
    assert_equal "Scheduling | Front desk", content_for(:title)
  ensure
    Lakeraven::EHR.configuration.product_name = "Lakeraven EHR"
  end

  test "page_header gives one h1, a sentence per lede paragraph, and actions" do
    @fragment = page_header("Find a patient", [ "Search first.", "Then register." ]) { link_to("Register", "/r") }

    assert_select ".page-header h1", text: "Find a patient", count: 1
    assert_select ".page-header p", count: 2
    assert_select ".page-header .page-header__actions a[href='/r']", text: "Register"
  end

  test "an error alert interrupts; a notice waits its turn" do
    @fragment = alert_box(:error, "RPMS refused the booking.", "Choose another time.", id: "refused") +
                 alert_box(:notice, "Booked.", id: "booked")

    assert_select "#refused.alert--error[role=alert] p", count: 2
    assert_select "#booked.alert--notice[role=status] p", text: "Booked."
  end

  test "flash_alert shows RPMS's reason when there is one, and nothing otherwise" do
    assert_nil flash_alert

    flash[:alert] = "Clinic is closed that day."
    @fragment = flash_alert(id: "clinic-alert")
    assert_select "#clinic-alert[role=alert]", text: /Clinic is closed that day\./
  end

  test "form_errors lists what is wrong under what was not done" do
    errors = ActiveModel::Errors.new(Lakeraven::EHR::PatientRegistration.new)
    errors.add(:base, "Date of birth is required")
    record = FakeForm.new(errors)

    @fragment = form_errors(record, "The registration was not saved.", id: "registration-errors")

    assert_select "#registration-errors[role=alert] p", text: "The registration was not saved."
    assert_select "#registration-errors li", text: "Date of birth is required"
    assert_equal "", form_errors(FakeForm.new(ActiveModel::Errors.new(nil)), "x").strip
  end

  test "form_field labels its input and ties the hint and error to it" do
    html = form_field(:dob, "Date of birth", hint: "As on their ID.", error: "Enter a date.") do |aria|
      date_field_tag :dob, nil, aria: aria
    end
    @fragment = html

    assert_select "label[for=dob]", text: "Date of birth"
    assert_select "input#dob[aria-describedby='dob_error dob_hint'][aria-invalid=true]"
    assert_select "#dob_hint", text: /As on their ID\./
    assert_select "#dob_error", text: /Enter a date\./
  end

  test "form_field with no hint or error adds no aria" do
    @fragment = form_field(:q, "Name") { |aria| text_field_tag :q, nil, aria: aria }

    assert_select "input#q:not([aria-describedby])"
  end

  test "choice_list is a fieldset with a legend, one labelled radio per choice" do
    html = form_with(scope: :registration, url: "/x") do |f|
      choice_list f, :sex, legend: "Sex", choices: [ [ "F", "Female" ], [ "M", "Male", { sex: "m" } ] ], selected: "M"
    end
    @fragment = html

    assert_select "fieldset legend", text: "Sex"
    assert_select "fieldset label input[type=radio][name='registration[sex]']", count: 2
    assert_select "label[data-sex=m] input[value=M][checked]"
    assert_select "input[value=F]:not([checked])"
  end

  test "lookup_field searches without validating, and keeps a choice already made" do
    html = form_with(scope: :checkin, url: "/x") do |f|
      lookup_field f, :provider_ien, legend: "Visit provider", search: :provider_search,
        search_label: "Provider name starts with", find_label: "Find provider", find_url: "/find",
        find_method: :get, choices: [], selected: "206", chosen_text: "Provider chosen."
    end
    @fragment = html

    assert_select "label.sr-only[for=provider_search]", text: "Provider name starts with"
    assert_select "button[type=submit]:not([name])[formaction='/find'][formmethod=get][formnovalidate]", text: "Find provider"
    assert_select "input[type=hidden][name='checkin[provider_ien]'][value='206']"
    assert_select "p.hint", text: "Provider chosen."
  end

  test "status_badge says the status in words, with a class per status" do
    @fragment = status_badge("no-show", "No-show")

    assert_select "span.status-badge.status-badge--no-show", text: "No-show"
  end

  test "empty_state says what is missing and offers the next step" do
    @fragment = empty_state("No patient matches.", id: "no-match") { link_to("Register a new patient", "/new") }

    assert_select "#no-match p", text: "No patient matches."
    assert_select "#no-match a[href='/new']", text: "Register a new patient"
  end

  test "patient_summary shows who, and nothing clinical" do
    @fragment = patient_summary({ name: "DEMO,ALPHA", mrn: "1234", dob: Date.new(1980, 2, 3), sex: "F" }, id: "registration")

    assert_select "#registration dd[data-field=hrn]", text: "1234"
    assert_select "#registration dd[data-field=dob]", text: "Feb 3, 1980"
    assert_select "#registration dt", count: 3
  end
end
