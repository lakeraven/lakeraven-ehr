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

  m.seed_collection(:patient_list,
    [ { dfn: 1, name: "Anderson,Alice" }, { dfn: 2, name: "MOUSE,MICKEY M" }, { dfn: 3, name: "DOE,JANE" } ],
    filter_field: :name)

  # Practitioners (IEN 101-102)
  m.seed(:practitioner_info, "101", { name: "MARTINEZ,SARAH", title: "MD", service_section: "Internal Medicine",
                                       specialty: "Cardiology", npi: "1234567890", phone: "907-555-9999", provider_class: "Physician" })
  m.seed(:practitioner_info, "102", { name: "CHEN,JAMES", title: "DO", service_section: "Surgery",
                                       specialty: "Orthopedic Surgery", npi: "2345678901", phone: "907-555-8888", provider_class: "Physician" })

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
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = "#{File.expand_path('fixtures', __dir__)}/files"
  ActiveSupport::TestCase.fixtures :all
end
