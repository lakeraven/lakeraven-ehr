# frozen_string_literal: true

module Lakeraven
  module EHR
    # One row per client assertion jti seen. The unique index on
    # [issuer, jti] is what makes a claim atomic: a replay loses the insert.
    class BackendAssertionJti < ApplicationRecord
      self.table_name = "lakeraven_ehr_backend_assertion_jtis"

      # Returns true when this jti is newly claimed, false when it has been
      # seen before. Scoped by issuer so one client cannot exhaust another's
      # jti space.
      def self.claim(issuer:, jti:, expires_at:)
        create!(issuer: issuer, jti: jti, expires_at: expires_at)
        true
      rescue ActiveRecord::RecordNotUnique
        false
      end

      # Rows are only useful until the assertion they guard has expired.
      def self.purge_expired(now = Time.current)
        where(expires_at: ...now).delete_all
      end
    end
  end
end
