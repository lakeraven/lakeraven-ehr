# frozen_string_literal: true

# Restores the default patient mock seeds from test_helper after examples that
# add ORHC demo patients or replace :patient_list.
module RpmsMockPatientSeedsHelper
  def restore_default_rpms_patient_seeds!
    client = RpmsRpc.client

    client.seed(:patient_select, "1", { name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15"), ssn: "111-11-1111", age: 45 })
    client.seed(:patient_select, "2", { name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14"), ssn: "000009999", age: 16 })
    client.seed(:patient_select, "3", { name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25"), ssn: "555667777", age: 35 })

    client.seed(:patient_id_info, "1", {
      ssn: "111-11-1111", dob: Date.parse("1980-05-15"), sex: "F",
      race_code: "I", site_ien: 7819, name: "Anderson,Alice"
    })
    client.seed(:patient_id_info, "2", {
      ssn: "000009999", dob: Date.parse("2010-02-14"), sex: "M",
      race_code: "I", site_ien: 7819, name: "MOUSE,MICKEY M"
    })
    client.seed(:patient_id_info, "3", {
      ssn: "555667777", dob: Date.parse("1990-12-25"), sex: "F",
      race_code: "I", site_ien: 7819, name: "DOE,JANE"
    })

    client.seed(:patient_ssn, "111-11-1111", { dfn: 1, name: "Anderson,Alice", ssn: "111-11-1111" })

    client.seed_collection(:patient_list,
      [
        { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15") },
        { dfn: 2, name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14") },
        { dfn: 3, name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25") }
      ],
      filter_field: :name)
  end
end
