# frozen_string_literal: true

# SMART on FHIR uses opaque pt_*-prefixed identifiers for the patient
# bound to a token. Doorkeeper's default oauth_access_tokens table
# stores resource_owner_id as a bigint (via t.references), which coerces
# any non-numeric string to 0. Change the column to a string so the
# patient identifier round-trips through token issuance + lookup.
#
# Same change applies to oauth_access_grants since the authorization
# code flow also threads patient context.
class ChangeOauthAccessTokensResourceOwnerIdToString < ActiveRecord::Migration[8.1]
  def up
    remove_index :oauth_access_tokens, :resource_owner_id if index_exists?(:oauth_access_tokens, :resource_owner_id)
    change_column :oauth_access_tokens, :resource_owner_id, :string
    add_index :oauth_access_tokens, :resource_owner_id

    remove_index :oauth_access_grants, :resource_owner_id if index_exists?(:oauth_access_grants, :resource_owner_id)
    change_column :oauth_access_grants, :resource_owner_id, :string
    add_index :oauth_access_grants, :resource_owner_id
  end

  def down
    remove_index :oauth_access_tokens, :resource_owner_id if index_exists?(:oauth_access_tokens, :resource_owner_id)
    change_column :oauth_access_tokens, :resource_owner_id, :bigint, using: "resource_owner_id::bigint"
    add_index :oauth_access_tokens, :resource_owner_id

    remove_index :oauth_access_grants, :resource_owner_id if index_exists?(:oauth_access_grants, :resource_owner_id)
    change_column :oauth_access_grants, :resource_owner_id, :bigint, using: "resource_owner_id::bigint"
    add_index :oauth_access_grants, :resource_owner_id
  end
end
