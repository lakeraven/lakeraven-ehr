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
          # The JSON branch records this from render_operation_outcome. The
          # HTML branch has to write the same denial or the audit row is missing.
          note_audit_denial("fhir operation refused: not-supported (HTTP #{response.status})")
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
      # An explicit application/fhir+json entry sets that JSON quality.
      # application/json and application/json+fhir stand in for it only when
      # the header has no explicit application/fhir+json entry; the highest
      # alias quality then applies. Order in the header does not matter.
      HTML_TYPE = "text/html"
      FHIR_JSON_TYPE = "application/fhir+json"
      FHIR_JSON_ALIASES = %w[application/json application/json+fhir].freeze

      # A quality value per RFC 9110: 0 to 1 with at most three decimals.
      QUALITY = /\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/

      # HTML wins only when it outranks FHIR JSON, or ties with it and is the
      # more specific match (so `text/html, */*` is HTML, a lone `*/*` and two
      # equally named types stay FHIR JSON). A header with any malformed q value
      # is unusable and falls to the FHIR JSON default, including a q parameter
      # with whitespace before `=` (`text/html;q =0`).
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
        entries = parsed_accept_entries(header)
        return nil unless entries

        explicit_fhir_json = entries.any? { |type, _quality| type.casecmp?(FHIR_JSON_TYPE) }
        entries.each_with_object({}) do |(type, quality), qualities|
          record_accept_quality(qualities, type, quality, explicit_fhir_json: explicit_fhir_json)
        end
      end

      def parsed_accept_entries(header)
        header.split(",").filter_map do |part|
          type, *params = part.split(";").map(&:strip)
          next if type.empty?

          return nil if params.any? { |param| q_parameter_with_space_before_equals?(param) }

          q_param = params.find { |param| param.downcase.start_with?("q=") }
          q = q_param ? q_param.split("=", 2).last.to_s.strip : "1"
          return nil unless q.match?(QUALITY)

          [ type, q.to_f ]
        end
      end

      # `q =0` is not a quality value: the name and `=` have to be adjacent.
      def q_parameter_with_space_before_equals?(param)
        name, value = param.split("=", 2)
        !value.nil? && name.strip.casecmp?("q") && name != name.strip
      end

      # Explicit application/fhir+json wins on its own, including when an
      # alias appears earlier or later in the header. Aliases contribute
      # only in its absence, and then the highest of them is kept.
      def record_accept_quality(qualities, type, quality, explicit_fhir_json:)
        type = type.downcase
        if type == FHIR_JSON_TYPE || (!explicit_fhir_json && FHIR_JSON_ALIASES.include?(type))
          qualities[FHIR_JSON_TYPE] = [ qualities[FHIR_JSON_TYPE], quality ].compact.max
        elsif !FHIR_JSON_ALIASES.include?(type)
          qualities[type] = quality
        end
      end

      # Runs from ApplicationController after the token checks and before the
      # search-parameter validators and any subclass patient-param callback,
      # so a withheld capability is not-supported rather than a 400.
      #
      # It is not a way around authorization. A caller this controller would
      # refuse on an available backend (a patient-bound token naming another
      # patient's compartment, a patient-level write scope on a create) is
      # refused the same way here, so only a caller who would be let in learns
      # that the capability is missing. Authorization is not repeated: the
      # controller's own checks run through authorize_before_unavailable!.
      # Render here, inside the action, rather than re-raising for rescue_from.
      # The audit wrapper records the row before rescue_from runs, so a denial
      # note written only in the renderer would miss the row. Rendering in this
      # callback leaves the note on the response the audit then records, and a
      # rendered before_action halts the chain the same way the raise did.
      def ensure_backend_supports_interaction!
        interaction = FHIR_ACTION_INTERACTIONS[action_name]
        capability = BackendRegistry.capability_for_fhir_interaction(fhir_resource_type, interaction)
        CapabilityGuard.ensure!(capability) if capability
      rescue FeatureUnavailable => error
        authorize_before_unavailable!
        render_feature_unavailable(error) unless performed?
      end

      # The authorization a controller declares beyond the token and scope
      # checks every controller shares. Renders 403 when it refuses. A
      # controller that declares such checks overrides this and calls super.
      def authorize_before_unavailable!; end

      def feature_unavailable_document(message)
        UNAVAILABLE_PAGE.sub("FEATURE_UNAVAILABLE_MESSAGE", ERB::Util.html_escape(message))
      end
    end
  end
end
