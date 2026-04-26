# frozen_string_literal: true

module Lakeraven
  module EHR
    # UdiParser — Parse UDI (Unique Device Identifier) strings
    #
    # ONC § 170.315(a)(14) requires parsing UDI into components:
    #   - Device Identifier (DI) — (01) Application Identifier
    #   - Production Identifiers (PI):
    #     - Lot/batch number — (10)
    #     - Serial number — (21)
    #     - Manufacturing date — (11)
    #     - Expiration date — (17)
    #
    # Supports GS1 Human Readable Form (HRF) with parenthesized AIs.
    # Ported from rpms_redux UdiParser.
    class UdiParser
      # GS1 Application Identifiers relevant to UDI
      AI_PATTERNS = {
        device_identifier: /\(01\)(\d{14})/,       # GTIN-14
        manufacture_date:  /\(11\)(\d{6})/,         # YYMMDD
        expiration_date:   /\(17\)(\d{6})/,         # YYMMDD
        lot_number:        /\(10\)([^\(]+)/,         # Variable length alphanumeric
        serial_number:     /\(21\)([^\(]+)/          # Variable length alphanumeric
      }.freeze

      def self.parse(udi_string)
        return {} if udi_string.blank?

        # Check for GS1 format (contains parenthesized AIs)
        unless udi_string.match?(/\(\d{2}\)/)
          return {}
        end

        return { carrier_hrf: udi_string } unless udi_string.include?("(01)")

        result = { carrier_hrf: udi_string }

        AI_PATTERNS.each do |key, pattern|
          match = udi_string.match(pattern)
          next unless match

          value = match[1].strip
          result[key] = date_field?(key) ? parse_gs1_date(value) : value
        end

        result
      end

      def self.date_field?(key)
        key == :manufacture_date || key == :expiration_date
      end

      # GS1 dates are YYMMDD. Years 00-49 map to 2000-2049; 50-99 to 1950-1999.
      def self.parse_gs1_date(yymmdd)
        return nil unless yymmdd.match?(/\A\d{6}\z/)

        yy = yymmdd[0, 2].to_i
        mm = yymmdd[2, 2].to_i
        dd = yymmdd[4, 2].to_i
        year = yy >= 50 ? 1900 + yy : 2000 + yy

        Date.new(year, mm, dd)
      rescue Date::Error
        nil
      end
    end
  end
end
