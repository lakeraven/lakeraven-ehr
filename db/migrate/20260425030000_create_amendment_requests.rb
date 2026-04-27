# frozen_string_literal: true

class CreateAmendmentRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_amendment_requests do |t|
      t.string :patient_dfn, null: false
      t.string :resource_type, null: false
      t.string :resource_id
      t.text :description, null: false
      t.text :reason, null: false
      t.string :requested_by, null: false
      t.string :status, null: false, default: "pending"
      t.string :reviewed_by
      t.text :review_reason
      t.datetime :reviewed_at
      t.timestamps
    end

    add_index :lakeraven_ehr_amendment_requests, :patient_dfn
    add_index :lakeraven_ehr_amendment_requests, :status
  end
end
