# VaccineBarcode - GS1-128/DataMatrix barcode parser for vaccine vials
#
# Parses GS1 Application Identifiers from barcode strings:
#   AI 01 → GTIN-14 (14 digits) — contains embedded NDC
#   AI 17 → Expiration date (YYMMDD)
#   AI 10 → Lot number (variable length, up to 20 chars)
#   AI 21 → Serial number (variable length, up to 20 chars)
#
# Accepts common scanner output formats:
#   - Raw element string:      0100364141234561...
#   - DataMatrix AIM prefix:   ]d20100364141234561...
#   - Human-readable parens:   (01)00364141234561...
#
# NDC extraction: GTIN-14 → strip indicator + check digit → raw 10-digit NDC.
# The 10-digit NDC is returned WITHOUT formatting because GTIN-14 does not encode
# the segment boundaries (5-4-1 vs 5-3-2 vs 4-4-2). Correct formatting requires
# an external database lookup (e.g., FDA NDC Directory or RPMS BINDC).
#
# @example
#   barcode = VaccineBarcode.parse("0100364141234561172603101012345")
#   barcode.ndc_code        # => "3641412345"
#   barcode.lot_number      # => "12345"
#   barcode.expiration_date # => #<Date: 2026-03-10>
#
module Lakeraven
  module EHR
    class VaccineBarcode
  attr_reader :gtin, :lot_number, :expiration_date, :serial_number

  # GS1 Application Identifier patterns
  AI_GTIN       = "01"  # Fixed 14 digits
  AI_EXPIRATION = "17"  # Fixed 6 digits (YYMMDD)
  AI_LOT        = "10"  # Variable length, up to 20
  AI_SERIAL     = "21"  # Variable length, up to 20

  FNC1 = "\x1D"

  # AIM identifiers prepended by scanners (e.g., ]d2 for GS1 DataMatrix)
  AIM_PREFIX = /\A\][a-zA-Z]\d/

  def initialize(gtin:, lot_number: nil, expiration_date: nil, serial_number: nil)
    @gtin = gtin
    @lot_number = lot_number
    @expiration_date = expiration_date
    @serial_number = serial_number
  end

  def self.parse(input)
    return new(gtin: nil) if input.nil? || input.empty?

    fields = extract_fields(input)
    return new(gtin: nil) unless fields[:gtin]

    new(
      gtin: fields[:gtin],
      lot_number: fields[:lot_number],
      expiration_date: parse_expiration(fields[:expiration]),
      serial_number: fields[:serial_number]
    )
  end

  def valid?
    @gtin.present? && @gtin.length == 14
  end

  # Best-effort NDC candidate extracted from GTIN-14 positions [2..11].
  #
  # WARNING: This is a LOCAL EXTRACTION ONLY — not authoritative. The GTIN-14
  # to NDC mapping depends on packaging indicator and GS1 prefix length, which
  # can vary. Use `lookup_vaccine` for authoritative NDC→vaccine resolution
  # via RPMS BINDC, or pass `gtin` directly to an external NDC database.
  #
  # Returns raw 10-digit string without dashes. Segment formatting
  # (5-4-1 vs 5-3-2 vs 4-4-2) is ambiguous and requires external lookup.
  def ndc_candidate
    return nil unless valid?

    @gtin[2..11]
  end

  # Preferred alias — callers should be aware this is a candidate, not verified
  alias_method :ndc_code, :ndc_candidate

  # Resolve barcode to authoritative vaccine info via RPMS gateway.
  # Uses full GTIN-14 lookup (BIPC GTINLOOKUP) — NOT the non-authoritative
  # ndc_candidate extraction, which can mis-map when GTIN packaging indicator
  # or GS1 prefix length varies.
  # @return [Hash, nil] { vaccine_code:, vaccine_display:, manufacturer: }
  def lookup_vaccine
    return nil unless valid?

    Immunization.lookup_by_gtin(@gtin)
  end

  private_class_method def self.extract_fields(input)
    fields = {}
    remaining = normalize_input(input)

    # Parse AI 01 (GTIN) — must be present, fixed 14 digits
    if remaining.sub!(/\A#{AI_GTIN}(\d{14})/, "")
      fields[:gtin] = $1
    else
      return fields
    end

    # Remove leading FNC1 separator
    remaining.delete_prefix!(FNC1)

    # Parse remaining AIs in any order
    loop do
      break if remaining.empty?
      remaining.delete_prefix!(FNC1)

      parsed = false

      # AI 17 (expiration) — fixed 6 digits
      if remaining.sub!(/\A#{AI_EXPIRATION}(\d{6})/, "")
        fields[:expiration] = $1
        parsed = true
      end

      # AI 10 (lot) — variable length, terminated by FNC1 or next AI or end
      if remaining.sub!(/\A#{AI_LOT}([^\x1D]{1,20}?)(?=\x1D|17|21|\z)/, "")
        fields[:lot_number] = $1
        parsed = true
      end

      # AI 21 (serial) — variable length, terminated by FNC1 or next AI or end
      if remaining.sub!(/\A#{AI_SERIAL}([^\x1D]{1,20}?)(?=\x1D|17|10|\z)/, "")
        fields[:serial_number] = $1
        parsed = true
      end

      break unless parsed
    end

    fields
  end

  # Strip scanner prefixes and human-readable formatting so the AI parser
  # sees a clean element string regardless of scanner output mode.
  private_class_method def self.normalize_input(input)
    str = input.dup
    # Strip AIM identifier prefix (e.g., ]d2 for GS1 DataMatrix, ]C1 for GS1-128)
    str.sub!(AIM_PREFIX, "")
    # Strip human-readable parentheses around AIs: (01)...(17)...(10)...(21)...
    str.gsub!(/\((\d{2})\)/, '\1')
    str
  end

  private_class_method def self.parse_expiration(yymmdd)
    return nil if yymmdd.nil? || yymmdd.length != 6

    year = 2000 + yymmdd[0..1].to_i
    month = yymmdd[2..3].to_i
    day = yymmdd[4..5].to_i

    return nil if month < 1 || month > 12

    # Day 00 means last day of month (GS1 convention)
    if day == 0
      Date.new(year, month, -1) # -1 gives last day of month in Ruby
    else
      Date.new(year, month, day)
    end
  rescue Date::Error
    nil
  end
    end
  end
end
