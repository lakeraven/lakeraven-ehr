# frozen_string_literal: true

# Names demo patients in a feature's own words. Each row must match
# features/support/rpms_demo_site.rb, which a live run checks against RPMS and
# a mock run seeds, so the table cannot say something RPMS does not.
Given("these RPMS demo patients:") do |table|
  table.hashes.each do |r|
    dfn = r["dfn"].to_i
    row = { name: r["name"], sex: r["sex"], dob: Date.parse(r["dob"]), ssn: r["ssn"] }
    assert_equal RpmsDemoSite::PATIENTS[dfn], row,
                 "DFN #{dfn} differs from the demo site (features/support/rpms_demo_site.rb)"
  end
end
