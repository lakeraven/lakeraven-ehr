# frozen_string_literal: true

module Lakeraven
  module EHR
    # Rejects replayed client assertions (SMART Backend Services: the server
    # SHALL not accept a jti it has previously encountered within the
    # assertion's lifetime).
    #
    # In-process store — sufficient for the current single-process deployment;
    # a multi-process deployment would move this to a shared store.
    class AssertionReplayGuard
      @seen = {}
      @mutex = Mutex.new

      class << self
        # Records the jti and returns false the first time; returns true when
        # the (client_id, jti) pair has already been used.
        def replayed?(client_id, jti, expires_at)
          key = "#{client_id}/#{jti}"
          @mutex.synchronize do
            prune
            return true if @seen.key?(key)

            @seen[key] = expires_at.to_i
            false
          end
        end

        def reset!
          @mutex.synchronize { @seen.clear }
        end

        private

        def prune
          now = Time.current.to_i
          @seen.delete_if { |_, exp| exp < now }
        end
      end
    end
  end
end
