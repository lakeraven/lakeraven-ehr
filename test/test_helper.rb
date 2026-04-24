# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"

# Configure RpmsRpc with mock client and seed data for all tests.
RpmsRpc.mock! do |m|
  # Patients (DFN 1-3)
  m.seed(:patient_select, "1", { name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15"), ssn: "111-11-1111", age: 45 })
  m.seed(:patient_select, "2", { name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14"), ssn: "000009999", age: 16 })
  m.seed(:patient_select, "3", { name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25"), ssn: "555667777", age: 35 })

  m.seed(:patient_id_info, "1", { race: "AMERICAN INDIAN", address_line1: "123 Main St", city: "Anchorage", state: "AK",
                                   zip_code: "99501", phone: "907-555-1234", tribal_enrollment_number: "ANLC-12345",
                                   service_area: "Anchorage", coverage_type: "IHS" })
  m.seed(:patient_id_info, "2", { race: "AMERICAN INDIAN", address_line1: "456 Disney Ave", city: "Orlando", state: "FL",
                                   zip_code: "32801", phone: "555-5678", tribal_enrollment_number: "NN-67890",
                                   service_area: "Arizona", coverage_type: "IHS/Medicaid" })
  m.seed(:patient_id_info, "3", { race: "AMERICAN INDIAN", tribal_enrollment_number: "CNO-24680",
                                   service_area: "Oklahoma", coverage_type: "IHS" })

  m.seed(:patient_ssn, "111-11-1111", { dfn: 1, name: "Anderson,Alice", ssn: "111-11-1111" })

  m.seed_collection(:patient_list,
    [ { dfn: 1, name: "Anderson,Alice" }, { dfn: 2, name: "MOUSE,MICKEY M" }, { dfn: 3, name: "DOE,JANE" } ],
    filter_field: :name)

  # Practitioners (IEN 101-102)
  m.seed(:practitioner_info, "101", { name: "MARTINEZ,SARAH", title: "MD", service_section: "Internal Medicine",
                                       specialty: "Cardiology", npi: "1234567890", dea_number: "AM1234563",
                                       phone: "907-555-9999", provider_class: "Physician" })
  m.seed(:practitioner_info, "102", { name: "CHEN,JAMES", title: "DO", service_section: "Surgery",
                                       specialty: "Orthopedic Surgery", npi: "2345678901",
                                       phone: "907-555-8888", provider_class: "Physician" })

  m.seed_collection(:practitioner_list,
    [ { ien: 101, name: "MARTINEZ,SARAH", title: "MD" }, { ien: 102, name: "CHEN,JAMES", title: "DO" } ],
    filter_field: :name)

  # Institutions (IEN 1)
  m.seed(:institution, "1", { ien: 1, name: "Alaska Native Medical Center", station_number: "463",
                               address: "4315 Diplomacy Dr", city: "Anchorage", state: "AK",
                               zip_code: "99508", phone: "907-729-1900" })

  # Locations (IEN 1)
  m.seed(:hospital_location, "1", { ien: 1, name: "Primary Care Clinic", abbreviation: "PCC",
                                     type: "C", division: "463" })

  # VFC Eligibility
  m.seed(:vfc_eligibility, "1", { code: "V04", label: "American Indian/Alaska Native" })
  m.seed_collection(:vfc_eligibility_list, [
    { code: "V01", label: "Not VFC eligible" },
    { code: "V02", label: "VFC eligible - Medicaid" },
    { code: "V03", label: "VFC eligible - Uninsured" },
    { code: "V04", label: "VFC eligible - AI/AN" },
    { code: "V05", label: "VFC eligible - FQHC" },
    { code: "V06", label: "VFC eligible - State specific" },
    { code: "V07", label: "VFC eligible - Local specific" }
  ])

  # Tribal enrollment (BHDPTRPC*)
  m.seed(:tribal_enrollment, "1", { enrollment_number: "ANLC-12345", tribe_name: "Alaska Native - Anchorage (ANLC)",
                                     enrollment_date: Date.new(2020, 1, 1), status: "ACTIVE",
                                     service_unit: "Anchorage", tribe_code: "ANLC" })
  m.seed(:tribal_validation, "ANLC-12345", { valid: true, tribe_code: "ANLC", enrollment_number: "12345",
                                              status: "ACTIVE", message: "Valid enrollment" })
  m.seed(:tribal_validation, "INVALID", { valid: false, tribe_code: nil, enrollment_number: nil,
                                           status: "INACTIVE", message: "Enrollment not found or inactive" })
  m.seed(:enrollment_eligibility, "1", { active: true, eligible_for_ihs: true,
                                          service_unit: "Anchorage", message: "Eligible for IHS services",
                                          benefit_package: "BASIC" })
  m.seed(:enrollment_eligibility, "4", { active: false, eligible_for_ihs: false,
                                          service_unit: nil, message: nil, benefit_package: nil })
  m.seed(:service_unit, "1", { ien: 1, name: "Anchorage", region: "Alaska" })
  m.seed(:tribe_info, "ANLC", { ien: 100, name: "Alaska Native - Anchorage (ANLC)", code: "ANLC",
                                  service_unit: "Anchorage", region: "Alaska", area: "Alaska Area" })
  m.seed(:tribe_info, "CN", { ien: 101, name: "Cherokee Nation", code: "CN",
                                service_unit: "Tahlequah", region: "Oklahoma", area: "Oklahoma City Area" })
  m.seed(:tribe_info, "NN", { ien: 102, name: "Navajo Nation", code: "NN",
                                service_unit: "Window Rock", region: "Arizona", area: "Navajo Area" })
  m.seed(:tribe_info, "OST", { ien: 104, name: "Oglala Sioux Tribe", code: "OST",
                                 service_unit: "Pine Ridge", region: "South Dakota", area: "Great Plains Area" })

  # Test users
  m.seed_user("301", credentials: "testprovider;test123", name: "PROVIDER,TEST", role: :provider)
  m.seed_user("302", credentials: "testnurse;test123", name: "NURSE,TEST", role: :nurse)
  m.seed_user("303", credentials: "testclerk;test123", name: "CLERK,TEST", role: :clerk)
  m.seed_user("304", credentials: "lindarodriguez;test123", name: "RODRIGUEZ,LINDA", role: :case_manager,
                     security_keys: [:prc_supervisor, :cprs_gui_chart])
end

# Shared auth helper for integration tests.
module SmartAuthTestHelper
  def setup_smart_auth(scopes: "system/*.read")
    @oauth_app = Doorkeeper::Application.create!(
      name: "test", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @oauth_app, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def teardown_smart_auth
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
  end
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = "#{File.expand_path('fixtures', __dir__)}/files"
  ActiveSupport::TestCase.fixtures :all
end
