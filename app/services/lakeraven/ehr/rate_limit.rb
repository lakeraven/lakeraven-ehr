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
    # addresses once it is spent. A bearer keeps a minimum of two: at a
    # budget of one the IP limb already refuses the repeat, and that single
    # hit must not spend the bucket of another client presenting the same
    # token.
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
    # A saturated IP can be parked outside the hot table while that table
    # still has room, so the address stays spent. A key at or over its
    # limit is never evicted, so a spent code or token is not reopened.
    #
    # Identity buckets and IP buckets each keep an eviction floor: a short
    # list of timestamps. Evicting a live counter merges its stamps into
    # that kind's floor as the pointwise maximum of the newest-first
    # stamps, capped at the larger limit in play. The floor's live count
    # is then an upper bound on every key of that kind the table has
    # dropped, so the holder cannot start over at zero. A new bucket is
    # seeded from its kind's live floor, and when that count is already at
    # the slot's limit the newcomer is refused. An IP victim leaves the
    # identity floor alone, so a fresh bearer still starts at zero when
    # only addresses were evicted. Nothing evicted in the window leaves the
    # floor empty. Expired keys are dropped and do not feed the floor.
    # reset! and configure_for_test! clear both floors.
    #
    # Admission is a dry run. The bounded search chooses the distinct
    # victims for every new slot without forgetting them: for a new
    # identity, the lightest under-limit identity, else the lightest
    # under-limit hot IP; for a new IP, the lightest under-limit hot IP.
    # Victims are evicted, buckets are created from the floors, and the
    # request is stamped only when those victims free enough room and
    # every new slot passes the floor check. A refusal changes nothing.
    # Expired keys may still be dropped during the search; they hold no
    # live count and are not merged into a floor.
    #
    # audit_due? is true the first time a stored key is at its limit in
    # the window, and the first time a request is refused because its
    # identity cannot be stored. Capacity refusals share one marker per
    # window, so junk identities cannot grow the audit map.
    class RateLimit
      DEFAULT_MAX_REQUESTS = 300
      DEFAULT_WINDOW = 1.minute
      DEFAULT_MAX_KEYS = 10_000
      SWEEP_EVERY = 64
      SWEEP_BATCH = 64
      EVICT_SAMPLE = 32
      EVICT_TRIES = 4
      AUDIT_DESCRIPTION = "request throttled"
      # One shared audited-map entry for every capacity refusal in the window.
      CAPACITY_AUDIT_KEY = "capacity"

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
          @floors = nil
          @floor_caps = nil
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

          place!(slots, now)
        end

        # Dry run: pick every victim, then evict and stamp only if the whole
        # request fits. A refusal leaves buckets, hot keys, and counters as
        # they were. Expired rows may already have been dropped.
        def place!(slots, now)
          ip_add = additions_for(slots, :ip)
          id_add = additions_for(slots, :id)
          return false unless admit!(ip_add, id_add, slots, now)

          slots.each { |slot| record_slot!(slot, now) }
          true
        end

        def admit!(ip_add, id_add, slots, now)
          victims = plan_victims(ip_add, id_add, slot_keys(slots), now, mutating: true)
          return false unless room_with?(ip_add, id_add, victims)
          return false unless floors_allow?(slots, victims, now)

          victims.each { |key| evict!(key, now) }
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
        # identity keeps a minimum of two so one hit at a budget of one does
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

        # Bounded search. Expired keys in the sample are dropped when this
        # is the admitting pass. Victims are chosen and not forgotten here.
        def plan_victims(ip_add, id_add, protected_keys, now, mutating:)
          victims = []
          EVICT_TRIES.times do
            break if room_with?(ip_add, id_add, victims)

            keys = sample_keys
            release_expired!(keys, protected_keys, now) if mutating
            next if room_with?(ip_add, id_add, victims)

            victim = victim_for(keys, protected_keys + victims, now, id_add.any?, mutating: mutating)
            victims << victim if victim && !victims.include?(victim)
          end
          victims
        end

        def victim_for(keys, protected_keys, now, new_identity, mutating:)
          found = lightest_key(keys, protected_keys, now, :id, mutating) if new_identity
          found || lightest_key(keys, protected_keys, now, :hot, mutating)
        end

        def room_with?(ip_add, id_add, victims)
          listed = victims.uniq.select { |key| buckets.key?(key) }
          hot_freed = listed.count { |key| hot.key?(key) }
          buckets.size - listed.size + ip_add.size + id_add.size <= max_keys &&
            hot.size - hot_freed + ip_add.size <= max_keys
        end

        def release_expired!(keys, protected, now)
          keys.each { |key| fresh_count(key, now) unless protected.include?(key) }
        end

        def lightest_key(keys, protected_keys, now, kind, mutating)
          best = nil
          keys.each do |key|
            rank = victim_rank(key, protected_keys, now, kind, mutating)
            best = rank if rank && (best.nil? || (rank <=> best).negative?)
          end
          best&.last
        end

        def victim_rank(key, protected_keys, now, kind, mutating)
          return if skip_victim?(key, protected_keys, kind)

          count = mutating ? fresh_count(key, now) : peek_count(key, now)
          entry = buckets[key]
          return if entry.nil? || count <= 0 || count >= entry[:limit]

          [ count, entry[:ord], key ]
        end

        # Count live stamps without pruning or deleting. audit_due? uses this
        # so a capacity check cannot evict or stamp.
        def peek_count(key, now)
          entry = buckets[key]
          return 0 unless entry

          threshold = cutoff(now)
          return entry[:stamps].size if entry[:stamps].empty? || entry[:stamps].first > threshold

          entry[:stamps].count { |at| at > threshold }
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
          entry = buckets[key] || seed_bucket!(key, limit, now)
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

        def seed_bucket!(key, limit, now)
          buckets[key] = { stamps: live_floor(key_kind(key), now), limit: limit, ord: next_ord }
        end

        def next_ord
          @seq = @seq.to_i + 1
        end

        # Live eviction only. Merges the counter into its kind's floor, then
        # drops it. Expiry uses forget! and must not raise the floor.
        def evict!(key, now)
          merge_evicted_floor!(key, now)
          forget!(key)
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
          if pending.any?
            pending.each { |key| audited[key] = now }
            return true
          end

          claim_capacity_audit!(identity, ip, now)
        end

        # One marker for the whole window, not one per junk identity.
        def claim_capacity_audit!(identity, ip, now)
          return false unless capacity_refusal?(identity, ip, now)
          return false if audited_recently?(CAPACITY_AUDIT_KEY, now)

          audited[CAPACITY_AUDIT_KEY] = now
          true
        end

        def capacity_refusal?(identity, ip, now)
          slots = slots_for(identity, ip)
          return false unless missing_identity?(slots)
          return false if slots.any? { |slot| peek_count(slot[:key], now) >= slot[:limit] }

          !admissible?(slots, now)
        end

        def missing_identity?(slots)
          slot = slots.find { |item| identity_slot?(item) }
          slot.present? && !buckets.key?(slot[:key])
        end

        def admissible?(slots, now)
          ip_add = additions_for(slots, :ip)
          id_add = additions_for(slots, :id)
          victims = plan_victims(ip_add, id_add, slot_keys(slots), now, mutating: false)
          room_with?(ip_add, id_add, victims) && floors_allow?(slots, victims, now)
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

        def floors_allow?(slots, victims, now)
          projected = project_floors(victims, now)
          slots.all? { |slot| slot_within_floor?(slot, projected) }
        end

        def slot_within_floor?(slot, projected)
          return true if buckets.key?(slot[:key])

          projected.fetch(slot_kind(slot)).size < slot[:limit]
        end

        def project_floors(victims, now)
          caps = floor_caps.dup
          projected = { id: live_floor(:id, now), ip: live_floor(:ip, now) }
          victims.each { |key| fold_projected_floor!(projected, caps, key, now) }
          projected
        end

        def fold_projected_floor!(projected, caps, key, now)
          entry = buckets[key]
          return unless entry

          kind = key_kind(key)
          stamps = live_only(entry[:stamps], now)
          return if stamps.empty?

          projected[kind], caps[kind] = merged_floor(projected[kind], caps[kind], stamps, entry[:limit])
        end

        def merge_evicted_floor!(key, now)
          entry = buckets[key]
          return unless entry

          prune_stamps!(entry[:stamps], now)
          return if entry[:stamps].empty?

          kind = key_kind(key)
          floors[kind], floor_caps[kind] = merged_floor(
            live_floor(kind, now), floor_caps[kind], entry[:stamps], entry[:limit]
          )
        end

        # Newest-first pointwise max. Index 0 is the most recent stamp, so
        # the merged list stays at least as new as either input and its live
        # count upper-bounds both. Length is capped at the larger limit.
        def merged_floor(floor, cap, stamps, limit)
          newest = pointwise_max(floor.reverse, stamps.reverse)
          new_cap = [ cap.to_i, limit.to_i ].max
          [ newest.take(new_cap).reverse, new_cap ]
        end

        def pointwise_max(left, right)
          length = [ left.size, right.size ].max
          Array.new(length) { |index| later_stamp(left[index], right[index]) }
        end

        def later_stamp(left, right)
          return right if left.nil?
          return left if right.nil?

          [ left, right ].max
        end

        def live_floor(kind, now)
          prune_stamps!(floor_for(kind), now)
          floor_for(kind).dup
        end

        def live_only(stamps, now)
          threshold = cutoff(now)
          return stamps if stamps.empty? || stamps.first > threshold

          stamps.drop_while { |at| at <= threshold }
        end

        def floor_for(kind)
          floors[kind] ||= []
        end

        def floors
          @floors ||= { id: [], ip: [] }
        end

        def floor_caps
          @floor_caps ||= { id: 0, ip: 0 }
        end

        def key_kind(key)
          identity_key?(key) ? :id : :ip
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

        # Nested controllers live under app/controllers/lakeraven/ehr/**.
        # controller_path already includes that subdirectory.
        def shipped_controller?(klass)
          root = Engine.root.join("app/controllers")
          root.join("#{klass.controller_path}_controller.rb").file?
        rescue StandardError
          false
        end

        def load_controller_declarations!
          root = Engine.root.join("app/controllers/lakeraven/ehr")
          Dir.glob(root.join("**/*_controller.rb")).each do |file|
            relative = Pathname.new(file).relative_path_from(root).sub_ext("").to_s
            EHR.const_get(relative.camelize)
          end
        end
      end
    end
  end
end
