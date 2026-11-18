# frozen_string_literal: true

require "rpms_rpc/fileman_date_parser"

module Lakeraven
  module EHR
    # The allergy entry form's values, in RPMS's terms (#1109).
    #
    # The form asks for what a clinician knows: an allergen picked from
    # RPMS's own search, dates from date pickers, a symptom picked from the
    # symptom catalog. RPMS takes an agent and its variable pointer, FileMan
    # dates and a symptom number. This turns the first into the second, so
    # nobody types a pointer, a FileMan date or a symptom number.
    #
    #   agent_choice    "POINTER^AGENT", a search match   -> agent, agent_pointer
    #   originated_on   "2026-11-10T14:30" (datetime-local) -> originated_at "3261110.1430"
    #   reaction_on     "2026-11-08" (date)                -> reaction_date "3261108"
    #   symptom_choice  "IEN^NAME", a catalog match        -> symptoms [ { ien, text, date } ]
    #   symptom_on      "2026-11-08" (date)                -> that symptom's date
    #
    # Every other key passes through untouched for the controller's strict
    # read. A form key beside the RPMS key it fills is refused: the request
    # would say two things. Times are the site's wall clock; a date or time
    # later than the site's now (SiteTime) is refused before RPMS is asked.
    class AllergyEntryForm
      FORM_KEYS = %w[agent_choice originated_on reaction_on symptom_choice symptom_on].freeze
      FILLS = {
        "agent_choice" => %w[agent agent_pointer],
        "originated_on" => %w[originated_at],
        "reaction_on" => %w[reaction_date],
        "symptom_choice" => %w[symptoms]
      }.freeze

      AGENT_CHOICE = /\A(?<pointer>[^\^]+)\^(?<agent>[^\^]+)\z/
      SYMPTOM_CHOICE = /\A(?<ien>[1-9]\d*)\^(?<name>[^\^]+)\z/
      LOCAL_TIME = /\A(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})T(?<hh>\d{2}):(?<mm>\d{2})(?::\d{2}(?:\.\d+)?)?\z/
      LOCAL_DATE = /\A(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})\z/

      # The values RPMS takes, or the reason the form's values were refused.
      Result = Struct.new(:allergy, :error, :chosen_agent, keyword_init: true) do
        def ok? = error.nil?
      end

      def self.to_rpms(raw, now:)
        new(raw, now).to_rpms
      end

      def initialize(raw, now)
        @raw = raw.to_h { |key, value| [ key.to_s, value ] }
        @now = now
      end

      def to_rpms
        form = @raw.slice(*FORM_KEYS)
        return Result.new(allergy: @raw) if form.empty?
        return refused(:invalid_value) unless form.values.all? { |value| value.is_a?(String) }
        return refused(:invalid_value) if conflicting?(form)

        allergy = @raw.except(*FORM_KEYS)
        chosen = fill_agent(allergy, form["agent_choice"])
        return refused(:invalid_value) if chosen == :invalid

        error = fill_dates(allergy, form) || fill_symptom(allergy, form)
        return refused(error) if error

        Result.new(allergy: allergy, chosen_agent: chosen)
      end

      private

      def refused(error) = Result.new(error: error)

      def conflicting?(form)
        FILLS.any? do |form_key, rpms_keys|
          form[form_key].present? && rpms_keys.any? { |key| @raw.key?(key) && @raw[key].present? }
        end
      end

      # nil when nothing was chosen, :invalid for a value not shaped as a
      # search match, else the chosen { agent:, agent_pointer: }.
      def fill_agent(allergy, choice)
        return if choice.blank?

        parts = AGENT_CHOICE.match(choice)
        return :invalid unless parts

        allergy["agent"] = parts[:agent]
        allergy["agent_pointer"] = parts[:pointer]
        { agent: parts[:agent], agent_pointer: parts[:pointer] }
      end

      def fill_dates(allergy, form)
        if form["originated_on"].present?
          time = local_time(form["originated_on"])
          return :invalid_value unless time
          return :future_date if time > @now

          allergy["originated_at"] = ::RpmsRpc::FilemanDateParser.format_datetime(time)
        end
        fill_date(allergy, "reaction_date", form["reaction_on"])
      end

      def fill_date(target, key, value)
        return if value.blank?

        date = local_date(value)
        return :invalid_value unless date
        return :future_date if date > @now.to_date

        target[key] = ::RpmsRpc::FilemanDateParser.format_date(date)
        nil
      end

      def fill_symptom(allergy, form)
        choice = form["symptom_choice"]
        if choice.blank?
          return form["symptom_on"].present? ? :invalid_value : nil
        end

        parts = SYMPTOM_CHOICE.match(choice)
        return :invalid_value unless parts

        row = { "ien" => parts[:ien], "text" => parts[:name], "date" => "" }
        error = fill_date(row, "date", form["symptom_on"])
        return error if error

        allergy["symptoms"] = [ row ]
        nil
      end

      # A wall-clock Time, built the way SiteTime and rpms-rpc build one.
      def local_time(value)
        parts = LOCAL_TIME.match(value)
        return unless parts

        Time.new(parts[:y].to_i, parts[:m].to_i, parts[:d].to_i, parts[:hh].to_i, parts[:mm].to_i, 0) if valid_date?(parts) && valid_clock?(parts)
      end

      def local_date(value)
        parts = LOCAL_DATE.match(value)
        Date.new(parts[:y].to_i, parts[:m].to_i, parts[:d].to_i) if parts && valid_date?(parts)
      end

      def valid_date?(parts) = Date.valid_date?(parts[:y].to_i, parts[:m].to_i, parts[:d].to_i)

      def valid_clock?(parts) = parts[:hh].to_i < 24 && parts[:mm].to_i < 60
    end
  end
end
