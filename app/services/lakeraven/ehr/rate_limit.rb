# frozen_string_literal: true

module Lakeraven
  module EHR
    # Throttle for every credentialed or clinical route (#498).
    #
    # Keyed on BOTH caller identity and client IP. Identity is the bearer
    # token, the backend-services client id (or the assertion when no client
    # id was sent), the session user, or the sign-in access code. Either limb
    # refuses the request: a token spread across addresses still trips, and
    # one address spraying tokens still trips. One identity on one address is
    # held to a tighter pair budget so it cannot outlast either limb.
    #
    # The counters live in this process. A multi-process deployment must back
    # this with a shared cache — another Puma worker does not see these hits,
    # and Rails.cache is not that store (the test environment uses a null
    # store, and a host that never configured one does not have one either).
    class RateLimit
      DEFAULT_MAX_REQUESTS = 300
      DEFAULT_WINDOW = 1.minute
      AUDIT_DESCRIPTION = "request throttled"

      class << self
        def throttled_route_keys
          load_controller_declarations!
          declared_keys.map(&:to_s).uniq.sort
        end

        def throttle_declarations
          throttled_route_keys
        end

        def register(controller_path, action)
          key = "#{controller_path}##{action}"
          declared_keys << key unless declared_keys.include?(key)
        end

        def configure_for_test!(max_requests:, window: DEFAULT_WINDOW)
          @max_requests = Integer(max_requests)
          @window = window
          @hits = {}
        end

        def reset!
          @max_requests = nil
          @window = nil
          @hits = {}
        end

        def permit?(identity:, ip:)
          now = Time.current
          slots = slots_for(identity, ip.to_s.presence || "unknown")
          return false if slots.any? { |slot| live_hits(slot[:key], now).length >= slot[:limit] }

          slots.each { |slot| live_hits(slot[:key], now) << now }
          true
        end

        def retry_after
          current_window.to_i
        end

        def max_requests
          @max_requests || DEFAULT_MAX_REQUESTS
        end

        private

        def declared_keys
          @declared_keys ||= []
        end

        def hits
          @hits ||= {}
        end

        def current_window
          @window || DEFAULT_WINDOW
        end

        # One wider than the pair budget. A token that changes address, or
        # many tokens behind one address, is still refused on the next
        # request; the pair refuses a single caller sooner.
        def limb_limit
          max_requests + 1
        end

        def slots_for(identity, ip)
          slots = []
          slots << pair_slot(identity, ip) if identity.present?
          slots << { key: "id:#{digest(identity)}", limit: limb_limit } if identity.present?
          slots << { key: "ip:#{digest(ip)}", limit: limb_limit }
          slots
        end

        def pair_slot(identity, ip)
          { key: "pair:#{digest(identity)}:#{digest(ip)}", limit: max_requests }
        end

        def live_hits(key, now)
          cutoff = now - current_window
          hits[key] = Array(hits[key]).select { |at| at > cutoff }
        end

        def digest(value)
          Digest::SHA256.hexdigest(value.to_s)
        end

        def load_controller_declarations!
          dir = Engine.root.join("app/controllers/lakeraven/ehr").to_s
          Dir.children(dir).each do |entry|
            next unless entry.end_with?("_controller.rb")

            EHR.const_get(entry.delete_suffix(".rb").camelize)
          end
        end
      end
    end
  end
end
