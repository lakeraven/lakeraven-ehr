# frozen_string_literal: true

class HardenLakeravenEHRLaunchContexts < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_launch_contexts, :oauth_application_uid, :string, null: false, default: ""
    add_column :lakeraven_ehr_launch_contexts, :consumed_at, :datetime

    # Defensively delete any pre-hardening rows that carry the
    # empty-string default. These rows have no OAuth client binding
    # and can never resolve under the new resolve(... oauth_application_uid:)
    # contract, so they're dead weight in the table regardless.
    reversible do |dir|
      dir.up do
        execute "DELETE FROM lakeraven_ehr_launch_contexts WHERE oauth_application_uid = ''"
      end
    end

    # Drop the default now that the column is populated. Future
    # inserts must specify the OAuth client explicitly.
    change_column_default :lakeraven_ehr_launch_contexts, :oauth_application_uid, from: "", to: nil

    add_index :lakeraven_ehr_launch_contexts, :oauth_application_uid
    add_index :lakeraven_ehr_launch_contexts, :expires_at
  end
end
