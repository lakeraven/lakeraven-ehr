# frozen_string_literal: true

module Lakeraven
  module EHR
    # App-side throttle for the sign-on POST.
    #
    # RPMS has its own three-strike lockout, but it keys on the BROKER client
    # IP — which, for a web app, is the app server. Without an app-side
    # throttle an unauthenticated attacker does not lock out one account; they
    # lock out EVERY clinician at once by tripping the shared lock. So this
    # has to exist before the login route is publicly reachable, and it has to
    # bite before RPMS's counter does.
    #
    # Throttling is keyed on BOTH the submitted access code and the client IP,
    # and either key tripping is enough: per-account keying alone lets one
    # source spray many accounts, and per-IP keying alone lets a distributed
    # source grind one account.
    #
    # A repeated lockout of the same account lengthens that account's window
    # (quadrupling, capped at a day). Doubling the 15-minute base never
    # reaches 24 hours inside six lockouts, and a memory equal to the cap
    # forgets the early rungs so the next lockout collapses (30 minutes).
    # Memory is a week — longer than the cap, and long enough that the climb
    # is still there after a cap-length wait. The IP limb stays on the base
    # window. The account is the first identifier; later ones are client
    # addresses. An access code is not classified by shape, so one that looks
    # like an IP address still backs off. A correct sign-in after the window
    # still succeeds, and success clears only the account.
    #
    # Deliberately in-process and time-bucketed. A single-process default is
    # the honest one for an engine that cannot assume a shared cache; a
    # multi-process deployment must back this with a shared store, and that is
    # stated in the PR rather than pretended away.
    class LoginThrottle
      MAX_ATTEMPTS = 5
      WINDOW = 15.minutes
      # A week, not 24h. The cap itself is 24h; remembering lockouts only that
      # long drops the rung that just ended. The climb plus a cap-length quiet
      # period is longer than 48h as well (the last rung is ~56h old), so the
      # ladder has to outlive both.
      LOCKOUT_MEMORY = 7.days
      BACKOFF_CAP = 24.hours

      class << self
        def attempts
          @attempts ||= {}
        end

        def reset!
          @attempts = {}
          @episodes = {}
          @lockout_times = {}
        end

        # True when this identifier has already spent its attempts. Checked
        # BEFORE credentials are validated, so a throttled caller is refused
        # even when the credential is correct — otherwise the throttle is a
        # speed bump rather than a lock.
        def throttled?(*identifiers)
          identifiers.each_with_index.any? do |identifier, index|
            next false if identifier.blank?

            live_attempts(identifier, account: index.zero?).length >= MAX_ATTEMPTS
          end
        end

        def record_failure(*identifiers)
          identifiers.each_with_index do |identifier, index|
            remember_failure(identifier, account: index.zero?)
          end
        end

        # A sign-on that succeeded clears the counter for THAT ACCOUNT only.
        #
        # It must never clear the client-IP counter. The IP limb exists to stop
        # spraying — many accounts, few attempts each — and clearing it on any
        # success handed the whole protection to anyone holding ONE valid
        # credential: 24 failures across four accounts from one address,
        # interleaved with the attacker's own good login, never reached the
        # limit. That also removes the guard against tripping RPMS's shared
        # broker-IP three-strike lock, which locks out every clinician at once.
        #
        # Consequence worth stating: a sprayed-from address stays limited for
        # the window even for its legitimate users, so a clinic behind one NAT
        # can be denied sign-on by an attacker sharing it. That is the correct
        # trade against a site-wide RPMS lockout, but it is a real cost.
        #
        # Lockout history for the account is kept for LOCKOUT_MEMORY, so the
        # next lockout still uses the longer window. Only the live strike
        # counter is cleared.
        def clear_account(access_code)
          return if access_code.blank?

          digested = account_key(access_code)
          attempts.delete(digested)
          episodes.delete(digested)
        end

        def retry_after(identifier = nil)
          window_for(identifier, account: true)
        end

        private

        def episodes
          @episodes ||= {}
        end

        def lockout_times
          @lockout_times ||= {}
        end

        # `account:` is positional: the first identifier is the access code,
        # whatever it looks like. A later identifier is the client address and
        # does not take the lengthening backoff.
        def remember_failure(identifier, account:)
          return if identifier.blank?

          prior = live_attempts(identifier, account: account)
          attempts[storage_key(identifier, account: account)] = prior + [ Time.current ]
          return unless account
          return unless prior.length + 1 == MAX_ATTEMPTS

          open_lockout(identifier)
        end

        def open_lockout(identifier)
          digested = account_key(identifier)
          now = Time.current
          level = recent_lockouts(digested).length
          episodes[digested] = { level: level, started_at: now }
          lockout_times[digested] = recent_lockouts(digested) + [ now ]
        end

        def recent_lockouts(digested)
          cutoff = Time.current - LOCKOUT_MEMORY
          Array(lockout_times[digested]).select { |at| at > cutoff }
        end

        def live_attempts(identifier, account:)
          key = storage_key(identifier, account: account)
          cutoff = Time.current - window_for(identifier, account: account)
          current = Array(attempts[key]).select { |at| at > cutoff }
          if current.empty?
            attempts.delete(key)
          else
            attempts[key] = current
          end
          current
        end

        def window_for(identifier, account:)
          base = WINDOW.to_i
          return base if identifier.blank? || !account

          episode = episodes[account_key(identifier)]
          return base unless episode && lockout_open?(episode)

          backoff_seconds(episode[:level])
        end

        def lockout_open?(episode)
          Time.current - episode[:started_at] < backoff_seconds(episode[:level])
        end

        # Quadruple, don't double. 15 minutes doubled six times is 8 hours,
        # so the documented day cap is unreachable in the lockouts a caller
        # can stack before the window itself is the story. 4**4 * 15 minutes
        # is the first step that the cap clips.
        def backoff_seconds(level)
          exponent = level.to_i.clamp(0, 6)
          seconds = WINDOW.to_i * (4**exponent)
          seconds > BACKOFF_CAP.to_i ? BACKOFF_CAP.to_i : seconds
        end

        def account_key(identifier)
          storage_key(identifier, account: true)
        end

        # The access code is a credential. It is never stored, logged, or used
        # as a map key in the clear — only its digest is. The prefix keeps an
        # access code that happens to be an IP address from sharing the
        # address's bucket.
        def storage_key(identifier, account:)
          prefix = account ? "acct" : "ip"
          "#{prefix}:#{Digest::SHA256.hexdigest(identifier.to_s)}"
        end
      end
    end
  end
end
