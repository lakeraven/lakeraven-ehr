# frozen_string_literal: true

module Lakeraven
  module EHR
    # One use of a front-desk "different person" review (rpms-ux S-REG-02). See
    # the migration: a review files a patient at most once.
    class RegistrationReview < ApplicationRecord
      self.table_name = "lakeraven_ehr_registration_reviews"

      # True for the first use of a review, false for every later one. The
      # unique index decides, so two requests at once cannot both win.
      def self.use!(review_id, duz:)
        # Its own savepoint: a refused insert must not abort the request's
        # transaction, or the audit row written after it fails too.
        transaction(requires_new: true) { create!(review_id: review_id.to_s, duz: duz.to_s, created_at: Time.current) }
        true
      rescue ActiveRecord::RecordNotUnique
        false
      end
    end
  end
end
