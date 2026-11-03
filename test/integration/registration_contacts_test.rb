# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-08 (emergency contact and next of kin). RpmsRpc::PatientProfile reads and files through AG's
# windows and runs AG's own field checks; these tests stand in for it at the
# gem boundary and check what the screens send and show.
class RegistrationContactsTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  # -- S-REG-08 ---------------------------------------------------------------

  test "S-REG-08.1 the contacts page shows both contacts as RPMS has them" do
    sign_in
    with_profile do
      get "#{BASE}/contacts"
    end

    assert_response :ok
    assert_select "#contact-emergency [data-field='name']", text: "DOE,JANE"
    assert_select "#contact-emergency [data-field='relationship']", text: "Spouse"
    assert_select "#contact-next-of-kin", text: /None on file/
  end

  test "S-REG-08.1 a contact's name, relationship, address and phones are sent to RPMS" do
    sign_in
    with_profile(contacts: ->(*) { { emergency: {}, next_of_kin: {} } },
                 update_contact: ->(*, **) { { success: true, dfn: DFN } }) do |calls|
      post "#{BASE}/contacts/next_of_kin", params: { contact: { name: "doe,john", relationship_ien: "1", address_line1: "1 MAIN ST",
                                                                city: "ANYTOWN", state_ien: "48", zip: "12345", phone: "555-555-0101",
                                                                phone_work: "555-555-0102" } }

      assert_redirected_to "#{BASE}/contacts"
      call = sent(calls, :update_contact).sole
      assert_equal [ DFN, :next_of_kin ], call[1]
      assert_equal({ name: "DOE,JOHN", relationship: "1", address_line1: "1 MAIN ST", city: "ANYTOWN", state: "48", zip: "12345",
                     phone: "555-555-0101", phone_work: "555-555-0102" }, call[2])
    end
  end

  test "S-REG-08.2 a new name with the old address left as it was sends only the name, so RPMS clears the old address" do
    sign_in
    with_profile(update_contact: ->(*, **) { { success: true, dfn: DFN } }) do |calls|
      post "#{BASE}/contacts/emergency", params: { contact: { name: "ROE,RICHARD", relationship_ien: "22", address_line1: "1 MAIN ST",
                                                              city: "ANYTOWN", state_ien: "48", zip: "12345", phone: "555-555-0100" } }

      assert_equal({ name: "ROE,RICHARD" }, sent(calls, :update_contact).sole[2])
    end
  end

  test "S-REG-08.3 a contact name not in LAST,FIRST form is refused and names the format" do
    sign_in
    with_profile do |calls|
      post "#{BASE}/contacts/emergency", params: { contact: { name: "JANE DOE" } }

      assert_response :unprocessable_content
      assert_select "#contact-errors", text: /LAST,FIRST MIDDLE,SUFFIX/
      assert_empty sent(calls, :update_contact)
    end
  end

  test "S-REG-08.3 RPMS's own refusal of a name is shown in its words" do
    sign_in
    with_profile(update_contact: ->(*, **) { { success: false, error: :invalid, field: :name, message: "No space after the comma" } }) do
      post "#{BASE}/contacts/emergency", params: { contact: { name: "ROE,RICHARD" } }

      assert_response :unprocessable_content
      assert_select "#contact-alert", text: /No space after the comma/
    end
  end

  test "S-REG-08.4 a relationship or phone with no name is refused and asks for the name" do
    sign_in
    with_profile(contacts: ->(*) { { emergency: {}, next_of_kin: {} } }) do |calls|
      post "#{BASE}/contacts/emergency", params: { contact: { relationship_ien: "22", phone: "555-555-0100" } }

      assert_response :unprocessable_content
      assert_select "#contact-errors", text: /Name is needed for a relationship, address or phone/
      assert_empty sent(calls, :update_contact)
    end
  end

  test "a view-only registration user sees contacts but cannot change them" do
    sign_in("registration_view_only")
    with_profile do
      get "#{BASE}/contacts"
      assert_response :ok
      assert_select "#edit-emergency", count: 0

      get "#{BASE}/contacts/emergency/edit"
      assert_response :forbidden
    end
  end

  test "the relationship look-up posts the form back and lists RPMS's matches" do
    sign_in
    with_profile(relationships: ->(text) { text == "SP" ? [ { ien: 22, name: "SPOUSE" } ] : [] }) do
      post "#{BASE}/contacts/emergency/edit", params: { relationship_search: "SP", contact: { name: "DOE,JANE" } }

      assert_response :ok
      assert_select "label[data-relationship='22']", text: /Spouse/
      assert_select "input[name='contact[name]'][value='DOE,JANE']"
    end
  end
end
