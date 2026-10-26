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
    # exceed the limit. A refused request does not mint a counter key.
    # permit? prunes only that request's keys. Expired keys are swept every
    # SWEEP_EVERY calls, a bounded batch at a time; sweep_expired! walks
    # the rest. max_keys counts every stored bucket: IP, identity, and the
    # backend-services (client, IP) pair, which is stored as an identity.
    # On a full table the victim is the lightest under-limit key in a
    # bounded random sample. Expired keys in that sample are dropped. A
    # key at or over its limit is never evicted, so a spent code or token
    # is not reopened. If the sample has no IP victim, the new IP is
    # refused. A saturated IP can be parked outside the hot table while
    # that table still has room, so the address stays spent.
    class RateLimit
      DEFAULT_MAX_REQUESTS = 300
      DEFAULT_WINDOW = 1.minute
      DEFAULT_MAX_KEYS = 10_000
      SWEEP_EVERY = 64
      SWEEP_BATCH = 64
      EVICT_SAMPLE = 32
      EVICT_TRIES = 4
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
            note_call!(now)
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

        # Every stored bucket: IP, identity, and parked saturated keys.
        def bucket_count
          mutex.synchronize { buckets.size }
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
          @order = []
          @key_index = {}
          @seq = 0
          @calls = 0
          @cursor = 0
        end

        def current_window
          @window || DEFAULT_WINDOW
        end

        def max_keys
          @max_keys || DEFAULT_MAX_KEYS
        end

        def grant?(identity, ip, now)
          slots = slots_for(identity, ip)
          return refuse_slots!(slots, now) if over_limit?(slots, now)

          ip_add = additions_for(slots, :ip)
          id_add = additions_for(slots, :id)
          protected = slot_keys(slots)
          return false unless hot_room!(ip_add, protected, now)

          kept = keep_identities!(id_add, ip_add, protected, now)
          record_kept!(slots, kept, now)
          true
        end

        def over_limit?(slots, now)
          slots.any? { |slot| fresh_count(slot[:key], now) >= slot[:limit] }
        end

        def additions_for(slots, kind)
          slots.filter_map { |slot| slot[:key] if slot_kind(slot) == kind && !buckets.key?(slot[:key]) }
        end

        def slot_kind(slot)
          identity_slot?(slot) ? :id : :ip
        end

        def slot_keys(slots)
          slots.map { |slot| slot[:key] }
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

        def identity_slot?(slot)
          slot[:key].start_with?("id:")
        end

        def identity_key?(key)
          key.start_with?("id:")
        end

        # Hot IP slots only. One bounded sample per try: drop expired keys in
        # that sample, otherwise the lightest live hot key under its limit.
        # No qualifying victim refuses the new IP.
        def hot_room!(ip_add, protected, now)
          needed = ip_add.size
          EVICT_TRIES.times do
            return true if hot_fits?(needed)

            keys = sample_keys
            release_expired!(keys, protected, now)
            return true if hot_fits?(needed)

            victim = lightest_key(keys, protected, now, :hot)
            return false unless victim

            forget!(victim)
          end
          hot_fits?(needed)
        end

        def hot_fits?(needed)
          hot.size + needed <= max_keys
        end

        # Identity buckets share max_keys with IP buckets. Evict an under-limit
        # identity from the sample. If the sample has none, the new identity
        # is not stored; a new IP that already fit in the hot table is still
        # recorded so a parked saturated address does not reopen.
        def keep_identities!(id_add, ip_add, protected, now)
          pending = id_add.dup
          EVICT_TRIES.times do
            return pending if total_fits?(ip_add, pending)

            keys = sample_keys
            release_expired!(keys, protected, now)
            return pending if total_fits?(ip_add, pending)

            victim = lightest_key(keys, protected, now, :id)
            if victim
              forget!(victim)
            else
              pending.pop
              return pending
            end
          end
          trim_identities!(pending, ip_add)
        end

        def trim_identities!(pending, ip_add)
          pending.pop while pending.any? && !total_fits?(ip_add, pending)
          pending
        end

        def total_fits?(ip_add, id_add)
          buckets.size + ip_add.size + id_add.size <= max_keys
        end

        def release_expired!(keys, protected, now)
          keys.each { |key| fresh_count(key, now) unless protected.include?(key) }
        end

        def lightest_key(keys, protected, now, kind)
          best = nil
          keys.each do |key|
            rank = victim_rank(key, protected, now, kind)
            best = rank if rank && (best.nil? || (rank <=> best).negative?)
          end
          best&.last
        end

        def victim_rank(key, protected, now, kind)
          return if skip_victim?(key, protected, kind)

          count = fresh_count(key, now)
          entry = buckets[key]
          return if entry.nil? || count <= 0 || count >= entry[:limit]

          [ count, entry[:ord], key ]
        end

        def skip_victim?(key, protected, kind)
          return true if protected.include?(key)
          return !hot.key?(key) if kind == :hot

          !identity_key?(key)
        end

        def sample_keys
          n = order.size
          return [] if n.zero?
          return order.dup if n <= EVICT_SAMPLE

          order.sample(EVICT_SAMPLE)
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

        def record_kept!(slots, kept_ids, now)
          allowed = kept_ids.each_with_object({}) { |key, map| map[key] = true }
          slots.each { |slot| record_slot!(slot, now) if keep_slot?(slot, allowed) }
        end

        def keep_slot?(slot, allowed)
          return true unless identity_slot?(slot)
          return true if buckets.key?(slot[:key])

          allowed[slot[:key]]
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
          remember_key!(key)
          entry[:limit] = limit
          entry[:stamps] << now
          entry
        end

        def remember_key!(key)
          return if key_index.key?(key)

          key_index[key] = order.size
          order << key
        end

        def new_entry(limit)
          @seq = @seq.to_i + 1
          { stamps: [], limit: limit, ord: @seq }
        end

        def forget!(key)
          buckets.delete(key)
          hot.delete(key)
          retained.delete(key)
          drop_key!(key)
        end

        def drop_key!(key)
          index = key_index.delete(key)
          return if index.nil?

          last = order.pop
          return if index == order.size

          order[index] = last
          key_index[last] = index
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

        def note_call!(now)
          @calls = @calls.to_i + 1
          sweep_batch!(now) if (@calls % SWEEP_EVERY).zero?
        end

        def sweep_batch!(now)
          sweep_some!(now, SWEEP_BATCH)
          sweep_audited!(now)
        end

        def sweep_expired_unlocked!(now)
          sweep_some!(now, order.size)
          sweep_audited!(now)
        end

        def sweep_some!(now, limit)
          scanned = 0
          while scanned < limit && order.any?
            @cursor = 0 if @cursor.to_i >= order.size
            size_before = order.size
            fresh_count(order[@cursor], now)
            scanned += 1
            @cursor = @cursor.to_i + 1 if order.size == size_before
          end
        end

        def sweep_audited!(now)
          threshold = cutoff(now)
          audited.delete_if { |_key, at| at <= threshold }
        end

        def cutoff(now)
          now - current_window
        end

        def digest(value)
          Digest::SHA256.hexdigest(value.to_s)
        end

        def order
          @order ||= []
        end

        def key_index
          @key_index ||= {}
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
