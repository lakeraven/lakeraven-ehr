# frozen_string_literal: true

# SMART Backend Services client bindings (Vardana source-system profile, section 2):
# - jwks_uri: the URL the client publishes (and rotates) its JWKS at; client
#   assertions are verified against these keys.
# - organization_id: the single organization the credential is scoped to
#   (e.g. "rpms-organization-101"). NULL means the credential is not
#   org-bound (interactive/user-context applications).
class AddBackendClientBindingsToOauthApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_applications, :jwks_uri, :string
    add_column :oauth_applications, :organization_id, :string
    add_index :oauth_applications, :organization_id
  end
end
