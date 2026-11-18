# frozen_string_literal: true

# The spent progress note form tokens (#1001).
#
# The browser session is a cookie the client holds, so a token struck from it
# comes back with an older copy of the cookie. A claim is a row here instead:
# the unique digest index makes the INSERT the one atomic test-and-set every
# process shares. The column is a SHA-256 hex digest of the token, never the
# token. No clinical data.
class CreateNoteFormClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_note_form_claims do |t|
      t.string :digest, null: false
      t.datetime :created_at, null: false
    end
    add_index :lakeraven_ehr_note_form_claims, :digest, unique: true,
              name: "index_lakeraven_ehr_note_form_claims_on_digest"
  end
end
