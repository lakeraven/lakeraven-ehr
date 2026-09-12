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
    # Deliberately in-process and time-bucketed. A single-process default is
    # the honest one for an engine that cannot assume a shared cache; a
    # multi-process deployment must back this with a shared store, and that is
    # stated in the PR rather than pretended away.
    class LoginThrottle
      MAX_ATTEMPTS = 5
      WINDOW = 15.minutes

      class << self
        def attempts
          @attempts ||= {}
        end

        def reset!
          @attempts = {}
        end

        # True when this identifier has already spent its attempts. Checked
        # BEFORE credentials are validated, so a throttled caller is refused
        # even when the credential is correct — otherwise the throttle is a
        # speed bump rather than a lock.
        def throttled?(*identifiers)
          identifiers.compact_blank.any? { |id| live_attempts(id).length >= MAX_ATTEMPTS }
        end

        def record_failure(*identifiers)
          identifiers.compact_blank.each do |id|
            attempts[key(id)] = live_attempts(id) + [ Time.current ]
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
        def clear_account(access_code)
          return if access_code.blank?

          attempts.delete(key(access_code))
        end

        def retry_after
          WINDOW.to_i
        end

        private

        def live_attempts(identifier)
          cutoff = Time.current - WINDOW
          (attempts[key(identifier)] || []).select { |t| t > cutoff }
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
