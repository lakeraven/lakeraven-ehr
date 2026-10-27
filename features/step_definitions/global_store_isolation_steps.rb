# frozen_string_literal: true

ISOLATION_REFERRAL_IEN = "ISOLATION-LEAK-589"

Given("a synthetic provenance record for isolation patient {string}") do |patient_key|
  Lakeraven::EHR::ProvenanceStore.instance.add(
    Lakeraven::EHR::Provenance.new(
      target_type: "Patient",
      target_id: "rpms-isolation-#{patient_key}",
      activity: "CREATE",
      agent_who_id: "synthetic-agent",
      agent_who_type: "Practitioner",
      recorded: Time.current
    )
  )
end

Given("an isolation mock referral is seeded for patient DFN {string}") do |dfn|
  RpmsRpc.client.seed_keyed_collection(:referral_search, dfn, [
    { ien: ISOLATION_REFERRAL_IEN, patient_dfn: dfn.to_i, status: "active", type: "C",
      date: Date.new(2026, 2, 1), provider: "SYNTHETIC,PROVIDER" }
  ])
end

Then("no provenance exists for isolation patient {string}") do |patient_key|
  target_id = "rpms-isolation-#{patient_key}"
  records = Lakeraven::EHR::ProvenanceStore.instance.for_target("Patient", target_id)
  assert_empty records,
               "ProvenanceStore leaked a record from a prior scenario; suite results depend on scenario order"
end

Then("no isolation mock referral exists for patient DFN {string}") do |dfn|
  referrals = Lakeraven::EHR::ServiceRequestGateway.for_patient(dfn)
  leaked = referrals.any? { |row| row[:ien].to_s == ISOLATION_REFERRAL_IEN }
  refute leaked,
         "RpmsRpc mock client leaked a referral_search seed from a prior scenario; suite results depend on scenario order"
end

Then("mock patient DFN {string} resolves to {string}") do |dfn, expected_name|
  patient = Lakeraven::EHR::PatientGateway.find(dfn)
  assert_not_nil patient,
                 "Baseline mock patient seed was wiped by an over-broad reset; suite results depend on scenario order"
  assert_equal expected_name, patient.name,
               "Baseline mock patient_select seed was wiped by an over-broad reset; suite results depend on scenario order"
end
