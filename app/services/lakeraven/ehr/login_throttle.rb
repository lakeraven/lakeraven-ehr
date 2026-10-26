# frozen_string_literal: true

require "ipaddr"

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
    # A repeated lockout of the same account within a day lengthens that
    # account's window (doubling, capped at a day). The IP limb stays on the
    # base window. A correct sign-in after the window still succeeds, and
    # success clears only the account.
    #
    # Deliberately in-process and time-bucketed. A single-process default is
    # the honest one for an engine that cannot assume a shared cache; a
    # multi-process deployment must back this with a shared store, and that is
    # stated in the PR rather than pretended away.
    class LoginThrottle
      MAX_ATTEMPTS = 5
      WINDOW = 15.minutes
      LOCKOUT_MEMORY = 24.hours
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
          identifiers.compact_blank.any? { |id| live_attempts(id).length >= MAX_ATTEMPTS }
        end

        def record_failure(*identifiers)
          identifiers.compact_blank.each { |id| remember_failure(id) }
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
        # Lockout history for the account is kept for the day, so the next
        # lockout still uses the longer window. Only the live strike counter
        # is cleared.
        def clear_account(access_code)
          return if access_code.blank?

          attempts.delete(key(access_code))
          episodes.delete(key(access_code))
        end

        def retry_after(identifier = nil)
          window_for(identifier)
        end

        private

        def episodes
          @episodes ||= {}
        end

        def lockout_times
          @lockout_times ||= {}
        end

        def remember_failure(identifier)
          prior = live_attempts(identifier)
          attempts[key(identifier)] = prior + [ Time.current ]
          return if ip_identifier?(identifier)
          return unless prior.length + 1 == MAX_ATTEMPTS

          open_lockout(identifier)
        end

        def open_lockout(identifier)
          digested = key(identifier)
          level = recent_lockouts(digested).length
          episodes[digested] = { level: level, started_at: Time.current }
          lockout_times[digested] = recent_lockouts(digested) + [ Time.current ]
        end

        def recent_lockouts(digested)
          cutoff = Time.current - LOCKOUT_MEMORY
          Array(lockout_times[digested]).select { |at| at > cutoff }
        end

        def live_attempts(identifier)
          cutoff = Time.current - window_for(identifier)
          current = Array(attempts[key(identifier)]).select { |at| at > cutoff }
          attempts[key(identifier)] = current
        end

        def window_for(identifier)
          base = WINDOW.to_i
          return base if identifier.blank? || ip_identifier?(identifier)

          episode = episodes[key(identifier)]
          return base unless episode && lockout_open?(episode)

          backoff_seconds(episode[:level])
        end

        def lockout_open?(episode)
          Time.current - episode[:started_at] < backoff_seconds(episode[:level])
        end

        def backoff_seconds(level)
          shift = level.to_i.clamp(0, 10)
          seconds = WINDOW.to_i * (2**shift)
          seconds > BACKOFF_CAP.to_i ? BACKOFF_CAP.to_i : seconds
        end

        def ip_identifier?(value)
          IPAddr.new(value.to_s)
          true
        rescue IPAddr::Error, ArgumentError
          false
        end

        # The access code is a credential. It is never stored, logged, or used
        # as a map key in the clear — only its digest is.
        def key(identifier)
          Digest::SHA256.hexdigest(identifier.to_s)
        end
      end
    end
  end
end
