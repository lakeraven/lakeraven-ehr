# frozen_string_literal: true

module Lakeraven
  module EHR
    # The SMART style a launched app may follow so it looks at home beside
    # this EHR (SMART App Launch, "smart_style_url"; #839). Every launched
    # token response names this URL. Public: it describes colours and type,
    # nothing about anyone.
    #
    # The values are the engine's own palette (Tailwind slate and the alert
    # colours the screens use).
    class SmartStylesController < ActionController::API
      STYLE = {
        color_background: "#f8fafc",
        color_error: "#b91c1c",
        color_highlight: "#0f172a",
        color_modal_backdrop: "rgba(15, 23, 42, 0.5)",
        color_success: "#15803d",
        color_text: "#0f172a",
        dim_border_radius: "0.25rem",
        dim_font_size: "1rem",
        dim_spacing_size: "1rem",
        font_family_body: "ui-sans-serif, system-ui, sans-serif",
        font_family_heading: "ui-sans-serif, system-ui, sans-serif",
        sms_style_version: "sss-0.1"
      }.freeze

      def show
        render json: STYLE
      end
    end
  end
end
