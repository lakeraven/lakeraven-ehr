# frozen_string_literal: true

require "rpms_rpc/api/symptom"

module Lakeraven
  module EHR
    # Allergy-symptom catalog lookup, for allergy entry and the order-entry
    # allergy precheck.
    # Wraps RpmsRpc::Symptom
    class SymptomGateway
      def self.search(query, via: default_provider)
        return [] if via.nil?

        via.search(query.to_s)
      end

      # The symptoms whose name starts with +text+, as
      #   [ { ien:, name:, label: } ]
      # +name+ is the symptom RPMS files (the preferred name when a synonym
      # matched); +label+ is what matched, with the preferred name beside a
      # synonym. RpmsRpc::Symptom.search walks the catalog from the entry
      # AFTER the text it is given (rpms-rpc#259), so that text is this one with its last letter
      # stepped back one, the list-box idiom; the page it returns is cut to
      # the names that start with the text.
      def self.starting_with(text, via: default_provider)
        prefix = text.to_s.strip.upcase
        return [] if prefix.empty? || via.nil?

        rows = via.search(walk_from(prefix))
        rows.filter_map { |row| starting_row(row, prefix) }.uniq { |row| [ row[:ien], row[:label] ] }
      end

      def self.defaults(via: default_provider)
        return [] if via.nil?

        via.defaults
      end

      def self.default_provider
        ::RpmsRpc::Symptom
      end

      def self.walk_from(prefix)
        "#{prefix[0..-2]}#{(prefix[-1].ord - 1).chr}~"
      end
      private_class_method :walk_from

      # A synonym row's name is SYNONYM<tab><PREFERRED> (rpms-rpc#221).
      def self.starting_row(row, prefix)
        matched, = row[:name].to_s.split("\t", 2)
        return unless matched.to_s.start_with?(prefix)

        preferred = row[:preferred_name].to_s.strip
        name = preferred.empty? ? matched : preferred
        label = preferred.empty? ? matched : "#{matched} (#{preferred})"
        { ien: row[:ien].to_s, name: name, label: label }
      end
      private_class_method :starting_row
    end
  end
end
