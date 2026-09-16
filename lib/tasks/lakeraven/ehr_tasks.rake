# frozen_string_literal: true

namespace :lakeraven_ehr do
  namespace :audit do
    desc "Report the PHI access log's integrity posture (digest mode, enforcement, unverified rows)"
    task integrity: :environment do
      events = Lakeraven::EHR::AuditEvent
      # INSTALLED facts, never adapter capabilities (#507 gate finding S1).
      append_only = if events.append_only_installed?
        "trigger installed and enabled"
      elsif events.append_only_enforceable?
        "NOT INSTALLED (adapter supports it — run lakeraven_ehr:audit:enforce_append_only; a schema load does not install it)"
      else
        "NOT available on this adapter"
      end
      puts "tamper-evident:  #{events.tamper_evident? ? 'yes (keyed digest + installed trigger)' : 'NO — do not cite this log as tamper-evident'}"
      puts "digest:          #{events.integrity_mode}"
      puts "append-only:     #{append_only}"
      puts "retention:       #{Lakeraven::EHR::AuditRetention.retention_period.inspect}"
      puts "records:         #{events.count}"

      unverified = events.tampered_events
      if unverified.empty?
        puts "unverified:      none — every record matches its digest"
      else
        puts "unverified:      #{unverified.size} record(s) altered or carrying no digest"
        unverified.first(50).each { |event| puts "  ##{event.id} recorded #{event.created_at&.iso8601}" }
        # A non-zero exit so a scheduled run is noticed rather than logged.
        exit 1
      end
    end

    desc "Delete PHI access records past the configured retention period (6 years minimum)"
    task purge: :environment do
      removed = Lakeraven::EHR::AuditRetention.purge!
      puts "purged #{removed} audit event(s) recorded before " \
           "#{Lakeraven::EHR::AuditRetention.cutoff.to_date.iso8601}"
    rescue Lakeraven::EHR::AuditRetention::RetentionPolicyError => e
      warn e.message
      exit 1
    end

    desc "Install the append-only enforcement the audit table depends on (idempotent)"
    task enforce_append_only: :environment do
      if Lakeraven::EHR::AuditEvent.enforce_append_only!
        puts "append-only enforcement installed on #{Lakeraven::EHR::AuditEvent.table_name}"
      else
        warn "this database adapter cannot enforce append-only; the digest still detects edits"
        exit 1
      end
    end
  end
end
