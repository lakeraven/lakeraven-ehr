# frozen_string_literal: true

require_relative "rpms_mock_patient_seeds_helper"

module OrhcDemoSeedHelper
  include RpmsMockPatientSeedsHelper

  # Minimal RPMS-shaped seed the adapter will mirror; MRN must be indexed for
  # identifier_search — not only echoed on Patient.identifier in responses.
  def seed_orhc_demo_patients!(site_ien: 5001)
    client = RpmsRpc.client
    [
      { dfn: "9101", name: "Kessler,Pat", sex: "F", dob: Date.parse("1959-04-12"),
        ssn: "900-00-9101", mrn: "ORHC-A" },
      { dfn: "9102", name: "Ames,Robin", sex: "M", dob: Date.parse("1955-11-03"),
        ssn: "900-00-9102", mrn: "ORHC-B" },
      { dfn: "9007", name: "DEMOPATIENT,OUTSIDE", sex: "M", dob: Date.parse("1980-04-18"),
        ssn: "900-00-9007", mrn: "ORHC-OUTSIDE", site_ien: 7000 }
    ].each do |row|
      client.seed(:patient_select, row[:dfn], {
        name: row[:name], sex: row[:sex], dob: row[:dob], ssn: row[:ssn], age: 65
      })
      client.seed(:patient_id_info, row[:dfn], {
        ssn: row[:ssn], dob: row[:dob], sex: row[:sex],
        race_code: "I", site_ien: row[:site_ien] || site_ien, name: row[:name],
        orhc_demo_mrn: row[:mrn]
      })
      client.seed(:patient_ssn, row[:ssn], { dfn: row[:dfn].to_i, name: row[:name], ssn: row[:ssn] })
    end
    client.seed_collection(:patient_list,
      [
        { dfn: 9101, name: "Kessler,Pat", sex: "F", dob: Date.parse("1959-04-12") },
        { dfn: 9102, name: "Ames,Robin", sex: "M", dob: Date.parse("1955-11-03") },
        { dfn: 9007, name: "DEMOPATIENT,OUTSIDE", sex: "M", dob: Date.parse("1980-04-18") }
      ],
      filter_field: :name)
  end

  def seed_orhc_patient_kessler!(site_ien: 5001)
    client = RpmsRpc.client
    client.seed(:patient_select, "9101", {
      name: "Kessler,Pat", sex: "F", dob: Date.parse("1959-04-12"),
      ssn: "900-00-9101", age: 67
    })
    client.seed(:patient_id_info, "9101", {
      ssn: "900-00-9101", dob: Date.parse("1959-04-12"), sex: "F",
      race_code: "I", site_ien: site_ien, name: "Kessler,Pat"
    })
  end
end
