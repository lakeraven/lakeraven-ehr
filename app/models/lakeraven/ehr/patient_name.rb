# frozen_string_literal: true

module Lakeraven
  module EHR
    # Value object for VistA-style patient names. Parses "LAST,FIRST MI"
    # and provides display/formal/FHIR formatting. Immutable after
    # construction — use a new instance when the name changes.
    #
    # Accepts either VistA format (name:) or separate parts
    # (first_name:, last_name:). If both are given, vista name wins.
    class PatientName
      attr_reader :family, :given, :text

      def initialize(name: nil, first_name: nil, last_name: nil)
        if name.present? && name.include?(",")
          parts = name.split(",", 2)
          @family = parts[0]&.strip
          given_str = parts[1]&.strip
          @given = given_str.present? ? given_str.split(/\s+/) : []
          @text = name
        elsif first_name.present? || last_name.present?
          @family = last_name.to_s.strip.presence
          @given = first_name.present? ? [ first_name.to_s.strip ] : []
          @text = [ @family, @given.first ].compact.join(",")
        else
          @family = nil
          @given = []
          @text = name.to_s
        end
        freeze
      end

      # "John Doe" — UI display
      def display
        parts = []
        parts << given.map(&:capitalize).join(" ") if given.any?
        parts << family&.capitalize if family.present?
        parts.join(" ").presence || text
      end

      # "Doe, John A" — clinical documents
      def formal
        return text unless family.present?

        capitalized_family = family.capitalize
        if given.any?
          capitalized_given = given.map(&:capitalize).join(" ")
          "#{capitalized_family}, #{capitalized_given}"
        else
          capitalized_family
        end
      end

      # "DOE,JOHN A" — VistA/MUMPS format
      def vista_format
        text
      end

      # Derived first_name (first given name)
      def first_name
        given.first&.capitalize
      end

      # Derived last_name (family name, capitalized)
      def last_name
        family&.capitalize
      end

      # FHIR HumanName hash
      def to_fhir
        return { text: text } unless family.present?
        result = { use: "official", family: family, given: given }
        result[:text] = text if text.present?
        result
      end
    end
  end
end
