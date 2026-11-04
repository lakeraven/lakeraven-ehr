# frozen_string_literal: true

# EHR launch (#839): a launch context names the user who launched it, so only
# that user can authorize with it, and a launch client names the URL the EHR
# sends the user to (its SMART launch URI), so a launch never goes to an
# address nobody registered.
class AddSmartLaunchBindings < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_launch_contexts, :duz, :string
    add_column :oauth_applications, :launch_uri, :text
  end
end
