# frozen_string_literal: true

module Lakeraven
  module EHR
    # The front desk's shared view pieces (docs/DESIGN-SYSTEM.md). Each helper
    # renders a partial under app/views/lakeraven/ehr/shared/, so the markup
    # stays ERB (DESIGN-PRINCIPLES 10); the helper only gathers its locals and
    # captures a block where the piece takes one.
    module ComponentsHelper
      SHARED = "lakeraven/ehr/shared"

      # The product's name in the chrome: one setting (Configuration#product_name).
      def product_name = Lakeraven::EHR.configuration.product_name

      # Sets the page's <title>: the parts, most specific first, then the
      # product name. page_title "Book", "Dental clinic"
      #   => "Book | Dental clinic | Lakeraven EHR"
      def page_title(*parts)
        content_for(:title, [ *parts, product_name ].compact_blank.join(" | "))
      end

      # The page's <h1>, a lede (a string, or an array of sentences, one <p>
      # each), and optional actions from the block.
      def page_header(title, lede = nil, &block)
        render "#{SHARED}/page_header", title: title, lede: lede, actions: (capture(&block) if block)
      end

      # A message box. kind :error is announced at once (role=alert);
      # :notice is announced politely (role=status). The messages are
      # sentences, one <p> each; a block adds more (a list, say).
      def alert_box(kind, *messages, id: nil, &block)
        render "#{SHARED}/alert", kind: kind, messages: messages.flatten.compact_blank, id: id,
          body: (capture(&block) if block)
      end

      # The flash alert a redirect carries, if any (RPMS's refusal, usually).
      def flash_alert(id: nil)
        alert_box(:error, flash[:alert], id: id) if flash[:alert].present?
      end

      # A form object's errors under one summary sentence: what was not done.
      def form_errors(record, summary, id: nil)
        render "#{SHARED}/form_errors", record: record, summary: summary, id: id
      end

      # A labelled input with an optional hint and error. The block renders the
      # input and receives the aria attributes that tie it to them:
      #   <%= form_field :dob, "Date of birth", form: f, hint: "As on their ID." do |aria| %>
      #     <%= f.date_field :dob, aria: aria %>
      #   <% end %>
      # The label's `for` is "<form object name>_<attribute>", the id Rails'
      # form builder gives the input; pass id: when the input's id differs.
      def form_field(attribute, label, form: nil, id: nil, hint: nil, error: nil, &block)
        field_id = id || (form ? "#{form.object_name}_#{attribute}" : attribute.to_s)
        hint_id = "#{field_id}_hint" if hint.present?
        error_id = "#{field_id}_error" if error.present?
        aria = { describedby: [ error_id, hint_id ].compact.join(" ").presence, invalid: (true if error_id) }.compact
        render "#{SHARED}/form_field", field_id: field_id, label: label, hint: hint, hint_id: hint_id,
          error: error, error_id: error_id, input: capture(aria, &block)
      end

      # A fieldset of radio buttons, one per choice. Each choice is
      # [value, label] or [value, label, data], the data hash going on the
      # choice's <label> (data-tribe="12", say). The block's content follows
      # the choices (a "Show reasons" button, say).
      def choice_list(form, attribute, legend:, choices:, selected: nil, inline: false, hint: nil, error: nil, before: nil, &block)
        render "#{SHARED}/choice_list", form: form, attribute: attribute, legend: legend, choices: choices,
          selected: selected, inline: inline, hint: hint, error: error, before: before,
          after: (capture(&block) if block)
      end

      # A choice found by searching RPMS: a "starts with" box and a Find
      # button that resubmits the form to find_url without validating it,
      # then the matches as radio buttons. A choice already made and not
      # re-searched is kept in a hidden field, with chosen_text saying so.
      def lookup_field(form, attribute, legend:, search:, search_label:, find_label:, find_url:, choices:,
                       selected: nil, find_method: :post, chosen_text: nil, empty_text: nil, hint: nil, error: nil)
        before = render("#{SHARED}/lookup_search", search: search, search_label: search_label,
          find_label: find_label, find_url: find_url, find_method: find_method)
        choice_list(form, attribute, legend: legend, choices: choices, selected: selected, hint: hint, error: error, before: before) do
          render "#{SHARED}/lookup_chosen", form: form, attribute: attribute, selected: selected,
            any_choices: choices.any?, chosen_text: chosen_text, empty_text: empty_text
        end
      end

      # A status's colour, by its key. Written out whole so the Tailwind build,
      # which reads this file, keeps each class. A key not here gets the
      # plain badge.
      STATUS_TONES = {
        "booked" => "status-badge--booked",
        "scheduled" => "status-badge--booked",
        "checked" => "status-badge--checked",
        "checked in" => "status-badge--checked",
        "no-show" => "status-badge--no-show",
        "no show" => "status-badge--no-show",
        "cancelled" => "status-badge--cancelled",
        "active" => "status-badge--active",
        "inactive" => "status-badge--inactive",
        "deceased" => "status-badge--deceased"
      }.freeze

      # A status in words, coloured by its key: status_badge("booked", "Booked").
      # The words carry the meaning; the colour only repeats it.
      def status_badge(key, label)
        render "#{SHARED}/status_badge", key: key.to_s, label: label,
          tone: STATUS_TONES[key.to_s.downcase]
      end

      # What a list shows when it has nothing in it: what is missing, and
      # what to do next if there is a next step (the block).
      def empty_state(*messages, id: nil, &block)
        render "#{SHARED}/empty_state", messages: messages.flatten.compact_blank, id: id,
          action: (capture(&block) if block)
      end

      # Who the front desk is looking at, without clinical data: name,
      # health record number, date of birth and sex.
      def patient_summary(patient, id: "patient-summary")
        render "#{SHARED}/patient_summary", patient: patient, id: id
      end
    end
  end
end
