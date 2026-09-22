# frozen_string_literal: true

module Lakeraven
  module EHR
    # Rejects replayed client assertions (SMART Backend Services: the server
    # SHALL not accept a jti it has previously encountered within the
    # assertion's lifetime).
    #
    # Backed by a database row per accepted jti with a unique
    # (client_id, jti) index: the INSERT is the atomic test-and-set, shared
    # across every process and surviving restarts. An earlier in-process
    # hash allowed one replay per Puma worker and unlimited replays across
    # restarts (independent security review finding).
    class AssertionReplayGuard
      class << self
        # Records the jti and returns false the first time; returns true when
        # the (client_id, jti) pair has already been used within the
        # assertion's lifetime.
        def replayed?(client_id, jti, expires_at)
          expires_at = Time.zone.at(expires_at.to_i)
          # An already-expired assertion is rejected upstream (JWT exp
          # verification); its replay window is over, so record nothing.
          return false if expires_at <= Time.current

          prune
          BackendAssertionJti.create!(client_id: client_id, jti: jti, expires_at: expires_at)
          false
        rescue ActiveRecord::RecordNotUnique
          true
        end

        def reset!
          BackendAssertionJti.delete_all
        end

        private

        # Rows are only meaningful within the assertion's lifetime; drop the
        # stale ones opportunistically (assertions live at most five minutes,
        # so the table stays tiny).
        def prune
          BackendAssertionJti.where(expires_at: ...Time.current).delete_all
        end
      end
    end
  end
end
