# frozen_string_literal: true

# Part 2 labels (#906, slice of #522). One row marks a record that holds,
# or may hold, 42 CFR Part 2 content. The row carries identifiers and a
# security code only, never clinical text. No trigger.
class CreateLakeravenEHRPart2Labels < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_part2_labels do |t|
      t.string :patient_dfn, null: false
      t.string :record_type, null: false
      t.string :record_id, null: false
      t.string :security_code, null: false
      t.timestamps
    end

    add_index :lakeraven_ehr_part2_labels, %i[record_type record_id], unique: true
  end
end
