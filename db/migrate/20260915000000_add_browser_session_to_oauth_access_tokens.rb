# frozen_string_literal: true

# Mark browser-SSO tokens intrinsically, at mint time.
#
# The predicate that decides whether a token is a browser credential used to
# compare `application.name` — a mutable display string with no unique index.
# Two applications can share it, and a rename silently re-classifies every live
# token. That matters because a browser token that stops being recognised stops
# being BOUND: it becomes replayable from an Authorization header, which is the
# defect the binding exists to prevent. An authorization decision cannot hang
# off an editable label.
class AddBrowserSessionToOauthAccessTokens < ActiveRecord::Migration[8.0]
  BROWSER_SSO_APP_NAME = "Lakeraven EHR Browser SSO"

  def up
    add_column :oauth_access_tokens, :browser_session, :boolean, default: false, null: false
    add_index :oauth_access_tokens, :browser_session

    # REVOKE existing browser-SSO tokens rather than backfilling the flag.
    #
    # Every token minted before this migration carries browser_session=false,
    # so it falls to the name-based classification this change exists to
    # escape — leaving the rename attack open for its remaining lifetime
    # (≤12h). Both review seats flagged it; the choice between backfill and
    # revoke is the interesting part.
    #
    # Backfill would re-rely on the exact fragility we are removing: it can
    # only find "the browser tokens" by application name, so if the application
    # were already renamed (the attack precondition) it would silently miss
    # them and stamp them as non-browser — the fail-open, migrated in.
    #
    # Revocation cannot key on the name either, for the same reason — the
    # round-2 gate reproduced a pre-flag token under an already-renamed
    # application surviving a name-keyed revoke and replaying from a header.
    # So the revoke matches by name OR BY SHAPE: browser tokens are the only
    # tokens this engine mints with a resource owner (the clinician's DUZ —
    # always set) and no patient/ scope (minting raises on one). The shape
    # clause therefore catches every browser token REGARDLESS of what the
    # application is called; the name clause is redundant belt.
    #
    # Deliberately over-broad, never under-: system/backend tokens have no
    # resource owner and survive (verified — the migration must not log
    # integrations out); patient-context tokens are excluded by scope. A HOST
    # app running its own non-patient authorization-code flow through the same
    # Doorkeeper tables would have those user tokens revoked too — a one-time
    # re-auth at migration, accepted as the fail-closed direction and stated
    # here rather than discovered.
    self.class.revoke_legacy_browser_tokens!(connection)
  end

  # Extracted so the security property can be tested against a seeded legacy
  # token without re-running the schema change.
  def self.revoke_legacy_browser_tokens!(conn)
    conn.execute(<<~SQL)
      UPDATE oauth_access_tokens
         SET revoked_at = CURRENT_TIMESTAMP
       WHERE revoked_at IS NULL
         AND (
           application_id IN (
             SELECT id FROM oauth_applications
              WHERE name = #{conn.quote(BROWSER_SSO_APP_NAME)}
           )
           OR (
             browser_session = #{conn.quoted_false}
             AND resource_owner_id IS NOT NULL
             AND scopes NOT LIKE '%patient/%'
           )
         )
    SQL
  end

  def down
    remove_index :oauth_access_tokens, :browser_session
    remove_column :oauth_access_tokens, :browser_session
    # The revocations are deliberately NOT undone: reviving a credential that
    # was retired for a security reason is not a rollback anyone wants.
  end
end
