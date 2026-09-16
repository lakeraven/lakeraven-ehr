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
  def change
    add_column :oauth_access_tokens, :browser_session, :boolean, default: false, null: false
    add_index :oauth_access_tokens, :browser_session
  end
end
