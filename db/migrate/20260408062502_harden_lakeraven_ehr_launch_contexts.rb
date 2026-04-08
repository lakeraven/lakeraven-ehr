# frozen_string_literal: true

class HardenLakeravenEHRLaunchContexts < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_launch_contexts, :oauth_application_uid, :string, null: false, default: ""
    add_column :lakeraven_ehr_launch_contexts, :consumed_at, :datetime

    # Drop the default after the column is created so future inserts
    # must specify the OAuth client. The empty-string default exists
    # only to satisfy the not-null constraint at add_column time on
    # any existing rows.
    change_column_default :lakeraven_ehr_launch_contexts, :oauth_application_uid, from: "", to: nil

    add_index :lakeraven_ehr_launch_contexts, :oauth_application_uid
    add_index :lakeraven_ehr_launch_contexts, :expires_at
  end
end
