# frozen_string_literal: true

# Demo patients of the pinned RPMS build, shared by any feature that needs one.

# The table is what the pinned RPMS build holds. Against the mock it is seeded
# into each RPC the patient reads use; against RPMS (LIVE_RPMS=1) each row is
# checked, so a row RPMS disagrees with fails the scenario instead of drifting.
Given("these RPMS demo patients:") do |table|
  rows = table.hashes.map do |r|
    { dfn: r["dfn"].to_i, name: r["name"], ssn: r["ssn"], dob: Date.parse(r["dob"]), sex: r["sex"] }
  end

  if LIVE_RPMS
    rows.each do |row|
      found = RpmsRpc::Patient.find(row[:dfn])
      assert found, "RPMS has no patient DFN #{row[:dfn]}"
      assert_equal row.except(:dfn), found.slice(:name, :ssn, :dob, :sex),
                   "RPMS disagrees with the table for DFN #{row[:dfn]}"
    end
  else
    mock = RpmsRpc.client
    rows.each do |row|
      mock.seed(:patient_select, row[:dfn].to_s, row.except(:dfn))
      mock.seed(:patient_id_info, row[:dfn].to_s, row.slice(:ssn, :dob, :sex, :name))
      mock.seed(:patient_ssn, row[:ssn], row.slice(:dfn, :name, :dob, :ssn))
    end
    # ORWPT LIST ALL answers a page of the name index whatever the start text
    # (rpms-rpc #352); the gateway does the prefix filtering.
    mock.seed_collection(:patient_list, rows.sort_by { |r| r[:name] }.map { |r| r.slice(:dfn, :name) })
  end
end
