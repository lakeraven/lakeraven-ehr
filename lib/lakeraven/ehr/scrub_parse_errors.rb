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
      LOGGER_KEY = "action_dispatch.logger"
      SILENT = ActiveSupport::Logger.new(IO::NULL)

      def initialize(app)
        @app = app
      end

      def call(env)
        request = ActionDispatch::Request.new(env)
        return @app.call(env) if parses?(request)

        Rails.logger.warn("#{MESSAGE}: #{request.request_method} #{request.path}")
        [ 400, { "content-type" => "text/plain" }, [ MESSAGE ] ]
      end

      private

      # Rails writes the raw body to its debug log when a parse fails, so the
      # parse runs with that logger silenced.
      def parses?(request)
        logger = request.get_header(LOGGER_KEY)
        request.set_header(LOGGER_KEY, SILENT)
        request.request_parameters
        true
      rescue ActionDispatch::Http::Parameters::ParseError, ActionController::BadRequest
        false
      ensure
        request.set_header(LOGGER_KEY, logger)
      end
    end
  end
end
