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
    # Revoking is unconditional. A revoked token cannot be replayed no matter
    # how it is later classified, so the window closes completely rather than
    # depending on a correct guess about which tokens are browser tokens. The
    # cost is one re-login on a short-lived session credential; nothing is
    # lost. Fail closed.
    self.class.revoke_legacy_browser_tokens!(connection)
  end

  # Extracted so the security property can be tested against a seeded legacy
  # token without re-running the schema change.
  def self.revoke_legacy_browser_tokens!(conn)
    conn.execute(<<~SQL)
      UPDATE oauth_access_tokens
         SET revoked_at = CURRENT_TIMESTAMP
       WHERE revoked_at IS NULL
         AND application_id IN (
           SELECT id FROM oauth_applications
            WHERE name = #{conn.quote(BROWSER_SSO_APP_NAME)}
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
