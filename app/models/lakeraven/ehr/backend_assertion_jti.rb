# frozen_string_literal: true

module Lakeraven
  module EHR
    # One accepted backend-services assertion jti (AssertionReplayGuard).
    # The unique (client_id, jti) index makes the INSERT the atomic
    # test-and-set shared by every process; rows are pruned once the
    # assertion's own lifetime has passed.
    class BackendAssertionJti < ApplicationRecord
      self.table_name = "lakeraven_ehr_backend_assertion_jtis"

      validates :client_id, :jti, :expires_at, presence: true
    end
  end
end
