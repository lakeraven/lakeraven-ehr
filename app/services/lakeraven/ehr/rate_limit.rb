# frozen_string_literal: true

module Lakeraven
  module EHR
    # Throttle for every credentialed or clinical route (#498).
    #
    # Keyed on BOTH caller identity and client IP. Identity is the bearer
    # token, the backend-services client id (or the assertion's iss when no
    # client id was sent), the session user, or the sign-in access code.
    # Either limb refuses the request: a token spread across addresses still
    # trips, and one address spraying tokens still trips. The IP limb's
    # budget is exactly max_requests. The identity limb matches that budget
    # once the configured limit is at least 2. A limit of 1 keeps a floor of
    # 2 on the identity limb so two clients behind one trusted proxy keep
    # separate address buckets when they present one bearer.
    #
    # The counters live in this process. A multi-process deployment must back
    # this with a shared cache — another Puma worker does not see these hits,
    # and Rails.cache is not that store (the test environment uses a null
    # store, and a host that never configured one does not have one either).
    #
    # Check-and-record in permit? holds a mutex so concurrent grants cannot
    # exceed the limit. A refused request does not mint a counter key. Empty
    # and expired keys are dropped, a sweep runs every SWEEP_EVERY calls, and
    # max_keys evicts the oldest entries. At the cap the limiter keeps
    # refusing; it does not fail open.
    class RateLimit
      DEFAULT_MAX_REQUESTS = 300
      DEFAULT_WINDOW = 1.minute
      DEFAULT_MAX_KEYS = 10_000
      SWEEP_EVERY = 64
      AUDIT_DESCRIPTION = "request throttled"

      @mutex = Mutex.new

      class << self
        def throttled_route_keys
          load_controller_declarations!
          (declared_keys + keys_from_controllers).map(&:to_s).uniq.sort
        end

        def throttle_declarations
          throttled_route_keys
        end

        def register(controller_path, action)
          key = "#{controller_path}##{action}"
          declared_keys << key unless declared_keys.include?(key)
        end

        # Controllers that declared `rate_limit`. Survives a test wiping
        # @declared_keys, because the class action sets are still populated.
        def observe_controller(klass)
          observed_controllers << klass unless observed_controllers.include?(klass)
        end

        def configure_for_test!(max_requests:, window: DEFAULT_WINDOW, max_keys: DEFAULT_MAX_KEYS)
          mutex.synchronize do
            @max_requests = Integer(max_requests)
            @window = window
            @max_keys = Integer(max_keys)
            clear_counters!
          end
        end

        def reset!
          mutex.synchronize do
            @max_requests = nil
            @window = nil
            @max_keys = nil
            clear_counters!
          end
        end

        def permit?(identity:, ip:)
          mutex.synchronize do
            now = Time.current
            sweep_if_due!(now)
            grant?(identity, ip.to_s, now)
          end
        end

        # True the first time this window refuses on a given counter key.
        # The caller writes at most one throttle audit per key per window.
        def audit_due?(identity:, ip:)
          mutex.synchronize { claim_audit!(identity, ip.to_s, Time.current) }
        end

        def key_count
          mutex.synchronize { hits.size }
        end

        def sweep_expired!
          mutex.synchronize { sweep_expired_unlocked!(Time.current) }
        end

        def retry_after
          current_window.to_i
        end

        def max_requests
          @max_requests || DEFAULT_MAX_REQUESTS
        end

        private

        def mutex
          @mutex
        end

        def declared_keys
          @declared_keys ||= []
        end

        def hits
          @hits ||= {}
        end

        def audited
          @audited ||= {}
        end

        def clear_counters!
          @hits = {}
          @audited = {}
          @calls = 0
        end

        def current_window
          @window || DEFAULT_WINDOW
        end

        def max_keys
          @max_keys || DEFAULT_MAX_KEYS
        end

        def grant?(identity, ip, now)
          slots = slots_for(identity, ip)
          return false if slots.any? { |slot| live_count(slot[:key], now) >= slot[:limit] }

          admit!(slots, now)
        end

        def slots_for(identity, ip)
          list = []
          list << limb("id", identity, identity_limit) if identity.present?
          list << limb("ip", ip.presence || "unknown", max_requests)
          list
        end

        def limb(kind, value, limit)
          { key: "#{kind}:#{digest(value)}", limit: limit }
        end

        # The IP limb already stops a second hit from the same address at a
        # budget of one. The identity floor stays at two so that single hit
        # does not spend the bucket of another address sharing the bearer.
        # From two upward the limbs are the same number, so a token rotated
        # across addresses stops on the request after max_requests. A zero
        # budget never grants: the IP limb refuses before a hit is stored.
        def identity_limit
          [ max_requests, 2 ].max
        end

        # Missing keys contribute zero and are not created. A refusal must
        # not mint a bucket for a bearer or address we have not already counted.
        def live_count(key, now)
          stamps = hits[key]
          return 0 unless stamps

          fresh = stamps.select { |at| at > cutoff(now) }
          if fresh.empty?
            hits.delete(key)
            0
          else
            hits[key] = fresh
            fresh.size
          end
        end

        def admit!(slots, now)
          keys = slots.map { |slot| slot[:key] }
          needed = keys.count { |key| !hits.key?(key) }
          return false unless make_room!(keys, needed)

          keys.each { |key| record_hit!(key, now) }
          true
        end

        # Evict the oldest key that this request does not itself need. If the
        # only way to make room is to forget a key we just measured, refuse.
        def make_room!(protected_keys, needed)
          return true if hits.size + needed <= max_keys

          while hits.size + needed > max_keys
            victim = hits.each_key.find { |key| !protected_keys.include?(key) }
            return false unless victim

            hits.delete(victim)
          end
          true
        end

        def record_hit!(key, now)
          bucket = hits[key] ||= []
          bucket << now
        end

        def claim_audit!(identity, ip, now)
          pending = refusing_keys(identity, ip, now).reject { |key| audited_recently?(key, now) }
          return false if pending.empty?

          pending.each { |key| audited[key] = now }
          true
        end

        def refusing_keys(identity, ip, now)
          slots_for(identity, ip).select { |slot| live_count(slot[:key], now) >= slot[:limit] }
            .map { |slot| slot[:key] }
        end

        def audited_recently?(key, now)
          at = audited[key]
          at.present? && at > cutoff(now)
        end

        def sweep_if_due!(now)
          @calls = @calls.to_i + 1
          sweep_expired_unlocked!(now) if (@calls % SWEEP_EVERY).zero?
        end

        def sweep_expired_unlocked!(now)
          threshold = cutoff(now)
          hits.delete_if do |_key, stamps|
            stamps.select! { |at| at > threshold }
            stamps.empty?
          end
          audited.delete_if { |_key, at| at <= threshold }
        end

        def cutoff(now)
          now - current_window
        end

        def digest(value)
          Digest::SHA256.hexdigest(value.to_s)
        end

        def observed_controllers
          @observed_controllers ||= []
        end

        # A test probe can call rate_limit without a shipped route. The
        # convention check walks this list and issues a request per key, so
        # only controllers that live under app/controllers belong here.
        def keys_from_controllers
          observed_controllers.flat_map do |klass|
            next [] unless klass.respond_to?(:rate_limited_actions)
            next [] unless shipped_controller?(klass)

            klass.rate_limited_actions.map { |action| "#{klass.controller_path}##{action}" }
          end
        end

        def shipped_controller?(klass)
          Engine.root.join("app/controllers/#{klass.controller_path}_controller.rb").file?
        rescue StandardError
          false
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
