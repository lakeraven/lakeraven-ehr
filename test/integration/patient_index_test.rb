# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# The clinician-facing way in to a patient's chart.
#
# The chart at /patients/:dfn has existed for a while, but only for someone who
# already knows a DFN. An index is what makes it reachable — and it has to carry
# exactly the protections the chart does, because a list is the surface most
# likely to leak a patient a credential should never see: the chart at least
# requires you to guess an identifier.
class PatientIndexTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    @original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! do |m|
      LakeravenDemoSeeds.seed(m)
      seed_patient_at_another_site(m)
    end
    setup_internal_smart_auth(scopes: "user/*.read")
  end

  teardown do
    teardown_smart_auth
    RpmsRpc.configure { |c| c.client = @original_client }
  end

  # --- it exists, and it is a way in ---------------------------------------

  test "the index lists patients and links each to its chart" do
    get "/patients", headers: @headers

    assert_response :success
    assert_match(%r{href="[^"]*/patients/#{known_dfn}"}, response.body,
      "every listed patient must link to its own chart")
    assert_select "h1", /Patients/i
  end

  test "the index shows enough to tell two patients apart" do
    get "/patients", headers: @headers

    assert_response :success
    body = response.body
    assert_match(/#{Regexp.escape(known_patient.display_name)}/, body,
      "a list of identifiers nobody recognises is not a way in")
    assert_match(/#{known_dfn}/, body, "the identifier a clinician would quote")
  end

  test "a name search narrows the list" do
    # RPMS name search is by surname; display_name is already humanized to
    # "First Last", so the surname is its last word.
    get "/patients", params: { name: known_patient.display_name.split.last }, headers: @headers

    assert_response :success
    assert_match(%r{href="[^"]*/patients/#{known_dfn}"}, response.body)
  end

  # --- it carries the chart's protections ----------------------------------

  test "an unauthenticated visitor gets nothing" do
    get "/patients"

    refute_equal 200, response.status,
      "the index must not be readable without a token"
  end

  test "a token without Patient read scope is refused" do
    token = token_with(scopes: "system/Observation.read")

    get "/patients", headers: bearer(token)

    assert_response :forbidden
  end

  # The negative case that matters: an organization-bound credential must not
  # see another organization's patients. The chart enforces this per patient;
  # a list enforces it for everyone at once, which is where it is easiest to
  # get wrong.
  test "an organization-bound token sees only its own organization's patients" do
    foreign = foreign_org_dfn

    get "/patients", headers: bearer(org_bound_token)

    assert_response :success
    assert_no_match(/\/patients\/#{foreign}\b/, response.body,
      "a patient outside the credential's organization must not be listed")
  end

  test "an organization-bound token cannot reach a foreign patient's chart from here either" do
    foreign = foreign_org_dfn

    get "/patients/#{foreign}", headers: bearer(org_bound_token)

    assert_includes [ 403, 404 ], response.status,
      "the index and the chart must agree about who is visible"
  end

  private

  def known_patient
    @known_patient ||= Lakeraven::EHR::Patient.search("").first
  end

  def known_dfn
    known_patient.dfn
  end

  FOREIGN_DFN = "9007"
  FOREIGN_SITE = 9999

  # The seed set is single-site, so the cross-organization case has to be made
  # rather than found. Without it the leak test silently skips, which is the
  # one test here that must not be allowed to pass by not running.
  def seed_patient_at_another_site(m)
    m.seed(:patient_select, FOREIGN_DFN, { name: "Farwood,Dale", sex: "M",
                                          dob: Date.parse("1966-02-09"), ssn: "900-00-9007", age: 60 })
    m.seed(:patient_id_info, FOREIGN_DFN, {
      ssn: "900-00-9007", dob: Date.parse("1966-02-09"), sex: "M",
      race_code: "I", site_ien: FOREIGN_SITE, name: "Farwood,Dale"
    })
    m.seed_collection(:patient_list,
      [ { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15") },
        { dfn: FOREIGN_DFN.to_i, name: "Farwood,Dale", sex: "M", dob: Date.parse("1966-02-09") } ],
      filter_field: :name)
  end

  def foreign_org_dfn
    FOREIGN_DFN
  end

  def org_bound_token
    site = Lakeraven::EHR::Patient.find_by_dfn(known_dfn)&.site_ien
    app = Doorkeeper::Application.create!(
      name: "org-bound-index", redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read", confidential: true,
      organization_id: "rpms-organization-#{site}"
    )
    Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read", expires_in: 3600
    )
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def token_with(scopes:)
    app = Doorkeeper::Application.create!(
      name: "scoped-index", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: 3600)
  end
end
