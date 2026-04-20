# frozen_string_literal: true

# Shared utilities, seed orchestration, and state reset for MockGatewayAdapter.
module MockAdapters
  module BaseMock
    def ensure_seeded!
      return if @seeded

      @mutex.synchronize do
        return if @seeded
        seed_test_data
        @seeded = true
      end
    end

    def stored_patients
      @created_patients
    end

    def stored_practitioners
      @created_practitioners
    end

    def seed_test_data
      seed_patients
      seed_practitioners
    end

    def clear!(allow_reseeding: true)
      @mutex.synchronize do
        @created_patients.clear
        @created_practitioners.clear
        @clinical_data&.clear
        @seeded = false if allow_reseeding
      end
    end

    def reset_test_state!
      clear!
    end

    def wildcard_to_regex(pattern)
      return nil if pattern.blank?
      escaped = Regexp.escape(pattern).gsub('\*', ".*")
      prefix = pattern.start_with?("*") ? "" : "^"
      suffix = pattern.end_with?("*") ? "" : "$"
      Regexp.new("#{prefix}#{escaped}#{suffix}", Regexp::IGNORECASE)
    end

    def name_matches_pattern?(name, pattern)
      return false if name.blank?
      return true if pattern.blank?
      clean_name = name.upcase.tr(" ,.-", "")
      clean_pattern = pattern.upcase.tr(" ,.-", "")
      last_name_only = name.include?(",") ? name.split(",")[0].upcase.tr(" ,.-", "") : nil
      if clean_pattern.include?("*")
        regex = wildcard_to_regex(clean_pattern)
        return true if last_name_only && (last_name_only =~ regex)
        return true if clean_name =~ regex
        false
      else
        (last_name_only && last_name_only.include?(clean_pattern)) || clean_name.include?(clean_pattern)
      end
    end

    def format_rpms_date(date)
      return "" unless date
      date.strftime("%b %d,%Y")
    end
  end
end
