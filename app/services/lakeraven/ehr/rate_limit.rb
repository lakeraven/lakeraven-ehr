# frozen_string_literal: true

module Lakeraven
  module EHR
    # Throttle for every credentialed or clinical route (#498).
    #
    # Keyed on BOTH caller identity and client IP. Identity is the bearer
    # token, the backend-services (client_id or iss, IP) pair, the session
    # user, or the sign-in access code. Either limb refuses the request: a
    # token spread across addresses still trips, and one address spraying
    # tokens still trips. The IP limb's budget is max_requests. An access
    # code uses that same budget, so one code cannot be replayed across
    # addresses once it is spent. A bearer keeps a floor of two: at a budget
    # of one the IP limb already refuses the repeat, and that single hit must
    # not spend the bucket of another client presenting the same token.
    #
    # The counters live in this process. A multi-process deployment must back
    # this with a shared cache — another Puma worker does not see these hits,
    # and Rails.cache is not that store (the test environment uses a null
    # store, and a host that never configured one does not have one either).
    #
    # Check-and-record in permit? holds a mutex so concurrent grants cannot
    # exceed the limit. A refused request does not mint a counter key. Empty
    # and expired keys are dropped, and a sweep runs every SWEEP_EVERY calls.
    # max_keys bounds the hot IP table. make_room! drops expired keys first,
    # then the live hot keys with the fewest hits. A key at or over its limit
    # is never evicted. Identity counters sit beside that table until they
    # expire, so eviction cannot reopen a spent code or token. If a new IP
    # key still will not fit, permit? refuses.
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
          mutex.synchronize { hot.size + retained.size }
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

        def buckets
          @buckets ||= {}
        end

        def hot
          @hot ||= {}
        end

        def retained
          @retained ||= {}
        end

        def audited
          @audited ||= {}
        end

        def clear_counters!
          @buckets = {}
          @hot = {}
          @retained = {}
          @audited = {}
          @seq = 0
          @calls = 0
        end

        def current_window
          @window || DEFAULT_WINDOW
        end

        def max_keys
          @max_keys || DEFAULT_MAX_KEYS
        end

        def grant?(identity, ip, now)
          drop_expired!(now)
          slots = slots_for(identity, ip)
          if slots.any? { |slot| fresh_count(slot[:key], now) >= slot[:limit] }
            return refuse_slots!(slots, now)
          end

          additions = hot_additions(slots, now)
          return false unless make_room!(protected_keys(slots, additions), additions, now)

          slots.each { |slot| record_slot!(slot, now) }
          true
        end

        def slots_for(identity, ip)
          list = []
          list << limb("id", identity, identity_limit_for(identity)) if identity.present?
          list << limb("ip", ip.presence || "unknown", max_requests)
          list
        end

        def limb(kind, value, limit)
          { key: "#{kind}:#{digest(value)}", limit: limit }
        end

        # Access codes spend max_requests across addresses. Every other
        # identity keeps a floor of two so one hit at a budget of one does
        # not exhaust a bearer shared by another address. A zero IP budget
        # still refuses before a hit is stored.
        def identity_limit_for(identity)
          return max_requests if identity.to_s.start_with?("access:")

          [ max_requests, 2 ].max
        end

        def refuse_slots!(slots, now)
          ip_slot = slots.find { |slot| !identity_slot?(slot) }
          retain_blocked_ip!(ip_slot[:key], now) if ip_slot
          false
        end

        # Missing keys contribute zero and are not created. A refusal must
        # not mint a bucket for a bearer or address we have not already counted.
        # Stamps are appended in order under the mutex, so a live oldest
        # stamp means the whole bucket is inside the window. Scanning every
        # stamp on every check made a 1500-grant flood outlive the window
        # and admit a second wave.
        def fresh_count(key, now)
          entry = buckets[key]
          return 0 unless entry

          prune_stamps!(entry[:stamps], now)
          return entry[:stamps].size unless entry[:stamps].empty?

          forget!(key)
          0
        end

        def prune_stamps!(stamps, now)
          threshold = cutoff(now)
          return if stamps.empty? || stamps.first > threshold

          expired = stamps.bsearch_index { |at| at > threshold } || stamps.size
          stamps.shift(expired)
        end

        def live_count(key, now)
          fresh_count(key, now)
        end

        def hot_additions(slots, now)
          slots.filter_map { |slot| addition_key(slot, now) }
        end

        # Identity counters are not hot keys. A limit of one saturates a
        # bearer-floor identity only on a later address, and parking that
        # first hit in the IP table would fill max_keys before the next
        # address is admitted. Spent identities stay in buckets until expiry.
        def addition_key(slot, _now)
          return if identity_slot?(slot)

          key = slot[:key]
          key unless hot.key?(key) || retained.key?(key)
        end

        def protected_keys(slots, additions)
          existing = slots.map { |slot| slot[:key] }.select { |key| buckets.key?(key) }
          (existing + additions).uniq
        end

        def identity_slot?(slot)
          slot[:key].start_with?("id:")
        end

        # Expired keys first, then the live hot keys with the fewest hits.
        # A key at or over its limit is not a victim. If nothing under the
        # limit can be spared, the new key is refused.
        def make_room!(protected, additions, now)
          drop_expired!(now)
          needed = additions.size
          return true if hot.size + needed <= max_keys

          while hot.size + needed > max_keys
            victim = eviction_victim(protected, now)
            return false unless victim

            forget!(victim)
          end
          true
        end

        def eviction_victim(protected, now)
          ranked = hot.keys.filter_map { |key| victim_rank(key, protected, now) }
          ranked.min&.last
        end

        def victim_rank(key, protected, now)
          return if protected.include?(key)

          count = fresh_count(key, now)
          entry = buckets[key]
          return if entry.nil? || count <= 0 || count >= entry[:limit]

          [ count, entry[:ord], key ]
        end

        # Saturated IP, refused while the hot table still has a free slot:
        # keep the counter, but outside the hot table, so the next new key
        # cannot reopen this address. A full hot table is left alone and the
        # new key is refused.
        def retain_blocked_ip!(key, now)
          return unless hot.key?(key)
          return unless saturated_entry?(key, now)
          return unless hot.size < max_keys
          return if retained.size >= max_keys

          hot.delete(key)
          retained[key] = true
        end

        def saturated_entry?(key, now)
          entry = buckets[key]
          entry && fresh_count(key, now) >= entry[:limit]
        end

        def record_slot!(slot, now)
          if identity_slot?(slot)
            record_identity!(slot[:key], now, slot[:limit])
          else
            record_ip!(slot[:key], now, slot[:limit])
          end
        end

        def record_identity!(key, now, limit)
          write_stamp!(key, now, limit)
        end

        def record_ip!(key, now, limit)
          write_stamp!(key, now, limit)
          hot[key] = true unless retained.key?(key)
        end

        def write_stamp!(key, now, limit)
          entry = (buckets[key] ||= new_entry(limit))
          entry[:limit] = limit
          entry[:stamps] << now
          entry
        end

        def new_entry(limit)
          @seq = @seq.to_i + 1
          { stamps: [], limit: limit, ord: @seq }
        end

        def forget!(key)
          buckets.delete(key)
          hot.delete(key)
          retained.delete(key)
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
          drop_expired!(now)
          threshold = cutoff(now)
          audited.delete_if { |_key, at| at <= threshold }
        end

        def drop_expired!(now)
          buckets.keys.each { |key| fresh_count(key, now) }
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
