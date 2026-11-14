# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #968: the bulk export routes answer as closed (a bare 404) until the
    # host names :bulk_export in config.x.lakeraven_ehr.open_disclosure_surfaces.
    class DisclosureSurfaceGateTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      ABSENT = Object.new.freeze
      EXPORT_ID = "00000000-0000-4000-8000-000000000968"

      # [ controller#action, verb, path ]
      BULK_EXPORT_ROUTES = [
        [ "exports#create",    :post,   "/lakeraven-ehr/exports" ],
        [ "exports#show",      :get,    "/lakeraven-ehr/exports/#{EXPORT_ID}" ],
        [ "exports#destroy",   :delete, "/lakeraven-ehr/exports/#{EXPORT_ID}" ],
        [ "export_files#show", :get,    "/lakeraven-ehr/exports/#{EXPORT_ID}/files/patient.ndjson" ]
      ].freeze

      # [ label, configured value, status with no Authorization header ]
      CONFIG_ROWS = [
        [ "the key is absent (closed by default)", ABSENT,                        :not_found ],
        [ "only other surfaces are named",         %i[fhir_api ccda],             :not_found ],
        [ "the value is a bare name, not a list",  :bulk_export,                  :not_found ],
        [ "bulk_export is opened by name",         %i[bulk_export],               :unauthorized ],
        [ "every surface is opened by name",       %i[fhir_api bulk_export ccda], :unauthorized ]
      ].freeze

      setup do
        @saved_options = Rails.application.config.x.lakeraven_ehr
        ExportsController.reset_store!
      end

      teardown do
        Rails.application.config.x.lakeraven_ehr = @saved_options
        ExportsController.reset_store!
        teardown_smart_auth
      end

      BULK_EXPORT_ROUTES.each do |route, verb, path|
        CONFIG_ROWS.each do |label, value, status|
          test "#{route} with no token answers #{status} when #{label}" do
            configure(value)
            send(verb, path)
            assert_response status
            status == :not_found ? assert_closed : assert_not_empty(response.body)
          end
        end
      end

      test "a closed bulk export answers a bare 404 even to a fully scoped token" do
        setup_smart_auth(scopes: "system/*.read system/*.write")
        configure(ABSENT)
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1" }, headers: @headers
        assert_closed
        assert_empty ExportsController.store, "a closed surface must not run the action"
      end

      test "bulk export opened by name serves a scoped token" do
        setup_smart_auth(scopes: "system/*.read system/*.write")
        configure(%i[bulk_export])
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1" }, headers: @headers
        assert_response :accepted
      end

      test "closing bulk export does not gate a FHIR Patient read" do
        configure(%i[fhir_api])
        get "/lakeraven-ehr/Patient/1"
        assert_response :unauthorized
      end

      test "the gate is on ApplicationController and an unknown name is refused at declaration" do
        assert_raises(ArgumentError) { Class.new(ApplicationController) { disclosure_surface :nope } }
        Class.new(ApplicationController) { disclosure_surface "ccda", only: :show }
        assert_includes ApplicationController.ancestors, DisclosureSurfaceGate
      end

      private

      def configure(value)
        options = ActiveSupport::OrderedOptions.new
        options[:open_disclosure_surfaces] = value unless value.equal?(ABSENT)
        Rails.application.config.x.lakeraven_ehr = options
      end

      def assert_closed
        assert_response :not_found
        assert_empty response.body
      end
    end
  end
end
