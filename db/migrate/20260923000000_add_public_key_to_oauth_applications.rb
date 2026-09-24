# frozen_string_literal: true

# SMART Backend Services authenticates a client by a signed JWT assertion
# (RFC 7523). Verifying that signature needs the client's public key, and there
# was nowhere to put one — so the token endpoint accepted any assertion whose
# payload named a known `iss`. See #496.
class AddPublicKeyToOauthApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_applications, :public_key, :text
  end
end
