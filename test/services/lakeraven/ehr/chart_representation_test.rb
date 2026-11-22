# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #969: which chart requests are the FHIR API surface. A request for the
    # FHIR representation is; so is any read that presents a bearer token.
    class ChartRepresentationTest < ActiveSupport::TestCase
      FHIR = "application/fhir+json"

      # [ label, format, _format, Accept, Authorization, fhir_requested?, fhir_api_request? ]
      ROWS = [
        [ "a plain browser read",               nil,    nil,    "text/html",          nil,           false, false ],
        [ "no Accept header at all",            nil,    nil,    nil,                  nil,           false, false ],
        [ "the .json extension",                "json", nil,    nil,                  nil,           true,  true ],
        [ "?_format=json",                      nil,    "json", "text/html",          nil,           true,  true ],
        [ "Accept: fhir+json",                  nil,    nil,    FHIR,                 nil,           true,  true ],
        [ "fhir+json among other Accept types", nil,    nil,    "text/html, #{FHIR};q=0.9", nil,     true,  true ],
        [ "Accept: application/json",           nil,    nil,    "application/json",   nil,           false, false ],
        [ "format=xml",                         "xml",  nil,    nil,                  nil,           false, false ],
        [ "_format=xml",                        nil,    "xml",  nil,                  nil,           false, false ],
        [ "HTML with a Bearer token",           nil,    nil,    "text/html",          "Bearer abc",  false, true ],
        [ "HTML with a lower-case bearer",      nil,    nil,    "text/html",          "bearer abc",  false, true ],
        [ "HTML with a Basic header",           nil,    nil,    "text/html",          "Basic abc",   false, false ],
        [ "Bearer with no token",               nil,    nil,    "text/html",          "Bearer",      false, false ],
        [ "Bearer and trailing space only",     nil,    nil,    "text/html",          "Bearer ",     false, false ],
        [ "a Basic header naming Bearer",       nil,    nil,    "text/html",          "Basic Bearer abc", false, false ],
        [ ".json with a Basic header",          "json", nil,    nil,                  "Basic abc",   true,  true ],
        [ ".json with a Bearer token",          "json", nil,    nil,                  "Bearer abc",  true,  true ]
      ].freeze

      ROWS.each do |label, format, underscore_format, accept, authorization, fhir, fhir_api|
        test "#{label}: fhir_requested? is #{fhir}, fhir_api_request? is #{fhir_api}" do
          request = build_request(format, underscore_format, accept, authorization)
          assert_equal fhir, ChartRepresentation.fhir_requested?(request)
          assert_equal fhir_api, ChartRepresentation.fhir_api_request?(request)
        end
      end

      private

      def build_request(format, underscore_format, accept, authorization)
        env = { "QUERY_STRING" => underscore_format ? "_format=#{underscore_format}" : "" }
        env["HTTP_ACCEPT"] = accept if accept
        env["HTTP_AUTHORIZATION"] = authorization if authorization
        ActionDispatch::TestRequest.create(env).tap do |request|
          request.path_parameters = { controller: "lakeraven/ehr/charts", action: "show", dfn: "1" }
            .merge(format ? { format: format } : {})
        end
      end
    end
  end
end
