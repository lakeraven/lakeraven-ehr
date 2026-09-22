# frozen_string_literal: true

# `public_key` was added in #535 to hold one static RSA key per backend client.
# #529 supersedes it with `jwks_uri`: SMART Backend Services clients publish a
# key set and rotate keys without re-registering, which a single pinned key
# cannot express. The column is unused after that change, and a dormant column
# holding key material is worth removing rather than leaving to be rediscovered.
class DropPublicKeyFromOauthApplications < ActiveRecord::Migration[8.1]
  def change
    remove_column :oauth_applications, :public_key, :text
  end
end
