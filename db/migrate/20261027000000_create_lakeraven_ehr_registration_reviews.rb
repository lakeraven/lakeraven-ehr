# frozen_string_literal: true

# A front-desk "different person" review (rpms-ux S-REG-02) may file a patient
# once. Two confirms of one review (a double click, a retried request) must not
# file two charts, so each review's id is written here before RPMS is asked, and
# the unique index lets exactly one of them through.
class CreateLakeravenEHRRegistrationReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_registration_reviews do |t|
      t.string :review_id, null: false
      t.string :duz, null: false
      t.datetime :created_at, null: false
    end
    add_index :lakeraven_ehr_registration_reviews, :review_id, unique: true
  end
end
