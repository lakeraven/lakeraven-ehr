# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR OperationOutcome and the HTML "not available" page, from one
    # place (#647). Gateways raise FeatureUnavailable; controllers do not
    # each decide how to say so.
    module FeatureUnavailableRendering
      extend ActiveSupport::Concern

      UNAVAILABLE_PAGE = <<~HTML.freeze
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Not available on this system</title>
        </head>
        <body>
          <h1>Not available on this system</h1>
          <p>FEATURE_UNAVAILABLE_MESSAGE</p>
        </body>
        </html>
      HTML

      included do
        rescue_from FeatureUnavailable, with: :render_feature_unavailable
      end

      private

      def render_feature_unavailable(error)
        if feature_unavailable_html?
          render html: feature_unavailable_document(error.message).html_safe, status: :not_found
        else
          render_operation_outcome(status: :not_found, severity: "error", code: "not-supported",
            diagnostics: error.message)
        end
      end

      # These routes are FHIR by default, including when Accept is absent
      # (Rails then negotiates HTML). The HTML page is for a client that
      # asks for HTML first — a browser, or Accept: text/html.
      def feature_unavailable_html?
        preferred_media_type.start_with?("text/html", "application/xhtml")
      end

      def preferred_media_type
        request.headers["Accept"].to_s.split(",").first.to_s.split(";").first.strip
      end

      def feature_unavailable_document(message)
        UNAVAILABLE_PAGE.sub("FEATURE_UNAVAILABLE_MESSAGE", ERB::Util.html_escape(message))
      end
    end
  end
end
