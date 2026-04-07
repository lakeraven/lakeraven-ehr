Lakeraven::EHR::Engine.routes.draw do
  use_doorkeeper
  # FHIR R4 Patient resource. The path uses the resource name (Patient,
  # not patients) per FHIR convention. The :identifier param is the
  # opaque pt_-prefixed token from ADR 0004 — never the backend DFN.
  get "Patient/:identifier", to: "patients#show", as: :patient,
      constraints: { identifier: %r{[^/]+} }
end
