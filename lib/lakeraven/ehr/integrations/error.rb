# frozen_string_literal: true

module Lakeraven
  module EHR
    module Integrations
      class Error
        CODES = %i[
          timeout
          connection_refused
          authentication_failed
          not_found
          parse_error
          validation_failed
          rate_limited
          service_unavailable
          unknown
        ].freeze

        RETRIABLE_CODES = %i[timeout connection_refused rate_limited service_unavailable].freeze

        attr_reader :code, :message, :source

        def initialize(code:, message: nil, source: nil)
          unless CODES.include?(code)
            raise ArgumentError, "Invalid error code: #{code.inspect}. Must be one of: #{CODES.join(', ')}"
          end

          @code = code
          @message = message || code.to_s.tr("_", " ")
          @source = source
        end

        def retriable?
          RETRIABLE_CODES.include?(@code)
        end

        def to_s
          parts = [ "[#{@code}]", @message ]
          parts << "(source: #{@source})" if @source
          parts.join(" ")
        end
      end
    end
  end
end
