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

      # Accept: application/fhir+json has to survive Rails' format filter,
      # which drops types that have no symbol. q-values are then Rails'
      # order, not the order the header was written in.
      Mime::Type.register "application/fhir+json", :fhir_json unless Mime[:fhir_json]

      FHIR_ACTION_INTERACTIONS = {
        "index" => "search-type",
        "show" => "read",
        "create" => "create",
        "update" => "update",
        "destroy" => "delete"
      }.freeze

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

      # FHIR JSON is the default. HTML is only when the client prefers it.
      # `_format` (and a format extension) win. Otherwise Rails request
      # formats honour Accept q-values. A browser-like Accept contains */*,
      # which makes Rails substitute HTML without reading those q-values;
      # text/html counts only when its q is at least as high as the rest.
      BROWSER_LIKE_ACCEPT = /,\s*\*\/\*|\*\/\*\s*,/

      def feature_unavailable_html?
        override = explicit_fhir_format
        if override
          request.format = override
          return override == :html
        end

        header = request.headers["Accept"].to_s
        return false if header.blank?
        return text_html_preferred?(header) if header.match?(BROWSER_LIKE_ACCEPT)

        html_format?(request.format)
      end

      def explicit_fhir_format
        token = params[:_format].presence || params[:format].presence
        token = token.to_s.split(";").first.to_s.strip.downcase
        return if token.empty?

        case token
        when "json", "application/json", "application/fhir+json" then :json
        when "html", "text/html", "application/xhtml+xml" then :html
        end
      end

      def text_html_preferred?(header)
        qualities = accept_qualities(header)
        html_q = qualities.fetch("text/html", 0.0)
        qualities.all? { |_type, quality| html_q >= quality }
      end

      def accept_qualities(header)
        header.split(",").each_with_object({}) do |part, qualities|
          type, *params = part.split(";").map(&:strip)
          next if type.empty?

          q_param = params.find { |param| param.downcase.start_with?("q=") }
          qualities[type.downcase] = q_param ? q_param.split("=", 2).last.to_f : 1.0
        end
      end

      def html_format?(mime)
        mime.respond_to?(:symbol) && mime.symbol == :html
      end

      # Runs from ApplicationController after the token checks and before a
      # subclass patient-param callback, so a withheld capability is
      # not-supported rather than a missing-parameter 400.
      def ensure_backend_supports_interaction!
        interaction = FHIR_ACTION_INTERACTIONS[action_name]
        capability = BackendRegistry.capability_for_fhir_interaction(fhir_resource_type, interaction)
        CapabilityGuard.ensure!(capability) if capability
      end

      def feature_unavailable_document(message)
        UNAVAILABLE_PAGE.sub("FEATURE_UNAVAILABLE_MESSAGE", ERB::Util.html_escape(message))
      end
    end
  end
end
