Lakeraven::EHR::Engine.routes.draw do
  # Doorkeeper's controllers live at top-level (Doorkeeper::TokensController etc.).
  # An isolated engine would otherwise try to resolve them under
  # Lakeraven::EHR::Doorkeeper::*; the leading-slash absolute paths
  # tell Rails routing to constantize them at the top level.
  use_doorkeeper do
    controllers tokens: "/doorkeeper/tokens",
                authorizations: "/doorkeeper/authorizations",
                applications: "/doorkeeper/applications",
                authorized_applications: "/doorkeeper/authorized_applications",
                token_info: "/doorkeeper/token_info"
  end

  # SMART App Launch discovery — clients hit this before they have a token.
  get ".well-known/smart-configuration", to: "smart/configuration#show"

  # FHIR R4 Patient resource. The path uses the resource name (Patient,
  # not patients) per FHIR convention. The :identifier param is the
  # opaque pt_-prefixed token from ADR 0004 — never the backend DFN.
  get "Patient/:identifier", to: "patients#show", as: :patient,
      constraints: { identifier: %r{[^/]+} }
end
