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
      # `_format` (and a format extension) win. Every other non-blank Accept goes
      # through one comparator (text_html_preferred?); Rails' own negotiation is
      # not consulted, because it ignores q=0 and quality ranking.
      def feature_unavailable_html?
        override = explicit_fhir_format
        if override
          request.format = override
          return override == :html
        end

        header = request.headers["Accept"].to_s
        return false if header.blank?

        text_html_preferred?(header)
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

      # The two representations this renderer can produce. Only they compete:
      # a range it cannot serve (application/xml) never decides, and each
      # type takes the quality of its most specific matching range, so an
      # explicit application/fhir+json;q=0.1 is not overridden by */*;q=1.
      HTML_TYPE = "text/html"
      FHIR_JSON_TYPE = "application/fhir+json"

      # A quality value per RFC 9110: 0 to 1 with at most three decimals.
      QUALITY = /\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/

      # HTML wins only when it outranks FHIR JSON, or ties with it and is the
      # more specific match (so `text/html, */*` is HTML, a lone `*/*` and two
      # equally named types stay FHIR JSON). A header with any malformed q value
      # is unusable and falls to the FHIR JSON default.
      def text_html_preferred?(header)
        ranges = accept_qualities(header)
        return false unless ranges

        html_q = effective_quality(ranges, HTML_TYPE)
        json_q = effective_quality(ranges, FHIR_JSON_TYPE)
        return false unless html_q.positive?

        html_q > json_q || (html_q == json_q && specificity(ranges, HTML_TYPE) > specificity(ranges, FHIR_JSON_TYPE))
      end

      def effective_quality(ranges, type)
        ranges[type] || ranges["#{type.split('/').first}/*"] || ranges["*/*"] || 0.0
      end

      # 2 for an exact range, 1 for type/*, 0 for */*, -1 for no match.
      def specificity(ranges, type)
        return 2 if ranges.key?(type)
        return 1 if ranges.key?("#{type.split('/').first}/*")

        ranges.key?("*/*") ? 0 : -1
      end

      # { "type/subtype" => q }, or nil when any q is malformed.
      def accept_qualities(header)
        header.split(",").each_with_object({}) do |part, qualities|
          type, *params = part.split(";").map(&:strip)
          next if type.empty?

          q_param = params.find { |param| param.downcase.start_with?("q=") }
          q = q_param ? q_param.split("=", 2).last.to_s.strip : "1"
          return nil unless q.match?(QUALITY)

          qualities[type.downcase] = q.to_f
        end
      end

      # Runs from ApplicationController after the token checks and before the
      # search-parameter validators and any subclass patient-param callback,
      # so a withheld capability is not-supported rather than a 400.
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
