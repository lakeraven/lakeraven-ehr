# frozen_string_literal: true

module Lakeraven
  module EHR
    # A request body Rails cannot parse never becomes a parameter, so
    # filter_parameters can't hide it, and the exception message carries the raw
    # text to the log (#709). That text can be clinical content. Parsing here,
    # before any controller runs, keeps it out of every controller's logging and
    # audit path: the request stops here with a 400, and the log names only the route.
    # A body that parses is cached on the request, so controllers read it as usual.
    class ScrubParseErrors
      MESSAGE = "The request body could not be parsed"

      def initialize(app)
        @app = app
      end

      def call(env)
        request = ActionDispatch::Request.new(env)
        begin
          request.request_parameters
        rescue ActionDispatch::Http::Parameters::ParseError, ActionController::BadRequest
          Rails.logger.warn("#{MESSAGE}: #{request.request_method} #{request.path}")
          return [ 400, { "content-type" => "text/plain" }, [ MESSAGE ] ]
        end
        @app.call(env)
      end
    end
  end
end
