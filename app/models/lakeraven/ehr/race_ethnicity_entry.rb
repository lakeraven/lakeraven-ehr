# frozen_string_literal: true

module Lakeraven
  module EHR
    # The patient's races and ethnicities, each with how it was collected
    # (rpms-ux S-REG-20.2 to 20.4): RACE INFORMATION (PATIENT 2.02) and
    # ETHNICITY INFORMATION (PATIENT 2.06), each entry a RACE (10) or ETHNICITY
    # (10.2) with its METHOD OF COLLECTION (10.3).
    #
    # The form sends, for each race or ethnicity the clerk ticks, its method:
    #   races: { "<ien>" => { "chosen" => "1", "method" => "<ien>" } }
    # At least one of each is needed (S-REG-20.3). RPMS checks the rest: a
    # code no longer active, or declined or unknown beside another (S-REG-20.4),
    # and its reason is shown.
    class RaceEthnicityEntry
      include ActiveModel::Model

      KINDS = { races: "race", ethnicities: "ethnicity" }.freeze

      # races and ethnicities: [{ code:, method: }], Integers.
      attr_reader :races, :ethnicities

      validate :one_of_each

      def initialize(races: [], ethnicities: [])
        super()
        @races = races
        @ethnicities = ethnicities
      end

      # From RpmsRpc::Registration.race_ethnicity: what is on file.
      def self.from_record(record)
        new(**KINDS.keys.to_h { |kind| [ kind, Array(record[kind]).map { |row| { code: row[:ien], method: row[:method] } } ] })
      end

      # From the form's params (see the class comment).
      def self.from_params(params)
        new(**KINDS.keys.to_h { |kind| [ kind, chosen(params&.dig(kind)) ] })
      end

      def self.chosen(rows)
        return [] unless rows.respond_to?(:to_h)

        rows.to_h.filter_map do |code, row|
          next unless row.respond_to?(:[]) && row["chosen"] == "1" && code.to_s.match?(/\A[1-9]\d*\z/)

          method = row["method"].to_s
          { code: code.to_i, method: method.match?(/\A[1-9]\d*\z/) ? method.to_i : nil }
        end
      end
      private_class_method :chosen

      def chosen?(kind, code) = public_send(kind).any? { |row| row[:code] == code.to_i }
      def method_for(kind, code) = public_send(kind).find { |row| row[:code] == code.to_i }&.dig(:method)

      private

      def one_of_each
        KINDS.each do |kind, name|
          rows = public_send(kind)
          if rows.empty?
            errors.add(kind, "Choose at least one #{name}.")
          elsif rows.any? { |row| row[:method].nil? }
            errors.add(kind, "Say how each #{name} was collected.")
          end
        end
      end
    end
  end
end
