# frozen_string_literal: true

module Lakeraven
  module EHR
    # A hard-coded, scored behavioural-health screening instrument (PHQ-9, GAD-7).
    #
    # Pure domain object — no I/O, no persistence, no Rails. It owns the item
    # text, the LOINC identity of every item and answer, the scoring rule and
    # the severity bands, so that scoring is testable without a database, a
    # session or an HTTP request. Persistence lives in ScreeningResponse and
    # ScreeningEntryService; FHIR shaping lives in the serializers.
    #
    # LOINC identity
    # --------------
    # `link_id` IS the item's LOINC code. That is the representation LOINC uses
    # for its own published FHIR Questionnaires (linkId == LOINC code under the
    # canonical `http://loinc.org/q/<panel-code>`), so a QuestionnaireResponse
    # built from these definitions resolves against the LOINC Questionnaire
    # without a local mapping table.
    #
    # Answer codes come from LOINC answer list LL358-3 (Not at all / Several
    # days / More than half the days / Nearly every day), shared by both
    # instruments.
    #
    # NOTE ON THE PHQ-9 TOTAL CODE (see PR discussion): issue #474 specifies
    # 44249-1 for the PHQ-9 total, and that is what is emitted here so the
    # trending work has a stable contract. In LOINC, 44249-1 is the PHQ-9
    # *panel* and 44261-6 is the *total score*; 70274-6 (GAD-7) is genuinely a
    # total score. This is flagged rather than silently "corrected" because the
    # code is an interface other issues are being written against. There is no
    # LOINC lookup in this engine to verify against: TerminologyService only
    # expands ValueSets (VSAC / local JSON), it cannot resolve a single code.
    class ScreeningInstrument
      # One question. `link_id` is the item's LOINC code; `position` is the
      # 1-based number the clinician sees ("9. Thoughts that you would be…").
      Item = Struct.new(:link_id, :position, :text, keyword_init: true)

      # One selectable answer. `value` is the ordinal that is summed.
      Choice = Struct.new(:value, :link_id, :text, keyword_init: true)

      # An inclusive severity band over the total score.
      Band = Struct.new(:range, :label, keyword_init: true) do
        def covers?(total) = range.cover?(total)
      end

      # Outcome of scoring a set of answers. Deliberately reports `total: nil`
      # for an incomplete instrument — an unscored screening must not be able
      # to masquerade as a zero.
      Score = Struct.new(:instrument, :answers, :total, :band, :missing_link_ids,
                         :safety_triggered, keyword_init: true) do
        def complete? = missing_link_ids.empty?
        def scored? = !total.nil?
        def safety_triggered? = !!safety_triggered

        # The clinician-facing "1, 4 and 7" list — positions, not LOINC codes.
        def missing_positions
          instrument.items.select { |i| missing_link_ids.include?(i.link_id) }.map(&:position)
        end
      end

      LOINC_SYSTEM = "http://loinc.org"

      # LOINC answer list LL358-3, shared by PHQ-9 and GAD-7.
      CHOICES = [
        Choice.new(value: 0, link_id: "LA6568-5", text: "Not at all"),
        Choice.new(value: 1, link_id: "LA6569-3", text: "Several days"),
        Choice.new(value: 2, link_id: "LA6570-1", text: "More than half the days"),
        Choice.new(value: 3, link_id: "LA6571-9", text: "Nearly every day")
      ].freeze

      attr_reader :key, :title, :short_title, :preamble, :panel_code,
                  :total_score_code, :total_score_display, :items, :bands,
                  :safety_link_id, :safety_guidance

      def initialize(key:, title:, short_title:, preamble:, panel_code:,
                     total_score_code:, total_score_display:, items:, bands:,
                     safety_link_id: nil, safety_guidance: nil)
        @key = key
        @title = title
        @short_title = short_title
        @preamble = preamble
        @panel_code = panel_code
        @total_score_code = total_score_code
        @total_score_display = total_score_display
        @items = items.freeze
        @bands = bands.freeze
        @safety_link_id = safety_link_id
        @safety_guidance = safety_guidance
        freeze
      end

      PHQ9 = new(
        key: "phq-9",
        title: "PHQ-9 depression screening",
        short_title: "PHQ-9",
        preamble: "Over the last 2 weeks, how often have you been bothered by any of the following problems?",
        panel_code: "44249-1",
        total_score_code: "44249-1",
        total_score_display: "PHQ-9 total score",
        items: [
          Item.new(link_id: "44250-9", position: 1, text: "Little interest or pleasure in doing things"),
          Item.new(link_id: "44255-8", position: 2, text: "Feeling down, depressed, or hopeless"),
          Item.new(link_id: "44259-0", position: 3, text: "Trouble falling or staying asleep, or sleeping too much"),
          Item.new(link_id: "44254-1", position: 4, text: "Feeling tired or having little energy"),
          Item.new(link_id: "44251-7", position: 5, text: "Poor appetite or overeating"),
          Item.new(link_id: "44258-2", position: 6,
                   text: "Feeling bad about yourself — or that you are a failure, or have let yourself or your family down"),
          Item.new(link_id: "44252-5", position: 7,
                   text: "Trouble concentrating on things, such as reading the newspaper or watching television"),
          Item.new(link_id: "44253-3", position: 8,
                   text: "Moving or speaking so slowly that other people could have noticed — or the opposite, " \
                         "being so fidgety or restless that you have been moving around a lot more than usual"),
          Item.new(link_id: "44260-8", position: 9,
                   text: "Thoughts that you would be better off dead, or of hurting yourself in some way")
        ],
        bands: [
          Band.new(range: 0..4,   label: "minimal"),
          Band.new(range: 5..9,   label: "mild"),
          Band.new(range: 10..14, label: "moderate"),
          Band.new(range: 15..19, label: "moderately severe"),
          Band.new(range: 20..27, label: "severe")
        ],
        safety_link_id: "44260-8",
        safety_guidance: "Item 9 indicates thoughts of self-harm. Complete a suicide-risk assessment with " \
                         "the patient before leaving this screen, and do not leave the patient unattended " \
                         "if there is imminent risk."
      )

      GAD7 = new(
        key: "gad-7",
        title: "GAD-7 anxiety screening",
        short_title: "GAD-7",
        preamble: "Over the last 2 weeks, how often have you been bothered by the following problems?",
        panel_code: "69737-5",
        total_score_code: "70274-6",
        total_score_display: "GAD-7 total score",
        items: [
          Item.new(link_id: "69725-0", position: 1, text: "Feeling nervous, anxious, or on edge"),
          Item.new(link_id: "68509-9", position: 2, text: "Not being able to stop or control worrying"),
          Item.new(link_id: "69733-4", position: 3, text: "Worrying too much about different things"),
          Item.new(link_id: "69734-2", position: 4, text: "Trouble relaxing"),
          Item.new(link_id: "69735-9", position: 5, text: "Being so restless that it is hard to sit still"),
          Item.new(link_id: "69689-8", position: 6, text: "Becoming easily annoyed or irritable"),
          Item.new(link_id: "69736-7", position: 7, text: "Feeling afraid, as if something awful might happen")
        ],
        bands: [
          Band.new(range: 0..4,   label: "minimal"),
          Band.new(range: 5..9,   label: "mild"),
          Band.new(range: 10..14, label: "moderate"),
          Band.new(range: 15..21, label: "severe")
        ]
      )

      ALL = [ PHQ9, GAD7 ].freeze

      def self.keys = ALL.map(&:key)

      def self.find(key)
        ALL.find { |i| i.key == key.to_s }
      end

      # Raises rather than returning nil — callers that name an instrument
      # (controllers, the entry service) should fail loudly on a typo.
      def self.find!(key)
        find(key) or raise ArgumentError, "Unknown screening instrument: #{key.inspect}"
      end

      def link_ids = items.map(&:link_id)
      def item_for(link_id) = items.find { |i| i.link_id == link_id.to_s }
      def choice_for(value) = CHOICES.find { |c| c.value == value }
      def max_score = items.length * CHOICES.map(&:value).max
      def safety_item = safety_link_id && item_for(safety_link_id)
      def safety_item? = !safety_link_id.nil?
      def questionnaire_canonical = "#{LOINC_SYSTEM}/q/#{panel_code}"

      # Score a hash of { link_id => ordinal }. Unknown link ids are ignored;
      # blank, non-numeric and out-of-range values are treated as UNANSWERED
      # rather than coerced to 0, so a hand-crafted submission cannot turn a
      # junk value into a scorable answer.
      def score(raw_answers)
        answers = normalize(raw_answers)
        missing = link_ids - answers.keys
        total = missing.empty? ? answers.values.sum : nil

        Score.new(
          instrument: self,
          answers: answers,
          total: total,
          band: total && band_label_for(total),
          missing_link_ids: missing,
          safety_triggered: safety_triggered?(answers)
        )
      end

      def band_label_for(total)
        bands.find { |b| b.covers?(total) }&.label
      end

      private

      # True as soon as the safety item carries any answer above "not at all",
      # INDEPENDENT of whether the rest of the instrument is complete — a
      # disclosure of self-harm is not something to sit on until the form is
      # finished.
      def safety_triggered?(answers)
        return false unless safety_link_id

        answers.fetch(safety_link_id, 0).positive?
      end

      def normalize(raw_answers)
        valid_values = CHOICES.map(&:value)
        (raw_answers || {}).each_with_object({}) do |(link_id, value), acc|
          key = link_id.to_s
          next unless link_ids.include?(key)

          ordinal = Integer(value.to_s, exception: false)
          next unless valid_values.include?(ordinal)

          acc[key] = ordinal
        end
      end
    end
  end
end
