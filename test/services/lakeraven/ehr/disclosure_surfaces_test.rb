# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The host-configured switch for the egress paths December does not need
    # (#522; audit docs/compliance/part2-disclosure-surface-audit.md §1 paths
    # 2–4, §5(a)). A host names the surfaces it wants OPEN in
    # Rails.application.config.x.lakeraven_ehr.open_disclosure_surfaces, an
    # Array of names drawn from fhir_api / bulk_export / ccda. Everything not
    # named is closed, and anything that is not such an Array closes everything:
    # the absence (or malformation) of configuration never opens a surface.
    class DisclosureSurfacesTest < ActiveSupport::TestCase
      ALL = %i[fhir_api bulk_export ccda].freeze

      setup do
        @config = Rails.application.config.x.lakeraven_ehr
        @had_key = @config.key?(:open_disclosure_surfaces)
        @original = @config.open_disclosure_surfaces
      end

      teardown do
        if @had_key
          @config.open_disclosure_surfaces = @original
        else
          @config.delete(:open_disclosure_surfaces)
        end
      end

      def set_open(value)
        @config.open_disclosure_surfaces = value
      end

      def assert_all_closed(message)
        ALL.each do |name|
          refute DisclosureSurfaces.open?(name), "#{name} should be closed when #{message}"
        end
      end

      # -- NAMES ---------------------------------------------------------------

      test "NAMES lists exactly the three disclosure surfaces" do
        assert_equal %i[bulk_export ccda fhir_api], DisclosureSurfaces::NAMES.map(&:to_sym).sort
        assert_equal 3, DisclosureSurfaces::NAMES.length
      end

      # -- Fail closed: nothing configured ------------------------------------

      test "no configuration key at all closes every surface" do
        @config.delete(:open_disclosure_surfaces)
        assert_all_closed "the key is absent"
      end

      test "nil closes every surface" do
        set_open nil
        assert_all_closed "the value is nil"
      end

      test "an empty Array closes every surface" do
        set_open []
        assert_all_closed "the value is []"
      end

      # -- Fail closed: not an Array -------------------------------------------

      test "true closes every surface" do
        set_open true
        assert_all_closed "the value is true"
      end

      test "the String all closes every surface" do
        set_open "all"
        assert_all_closed "the value is \"all\""
      end

      test "a bare surface name String closes every surface" do
        set_open "fhir_api"
        assert_all_closed "the value is the bare String \"fhir_api\""
      end

      test "a Hash closes every surface" do
        set_open({ fhir_api: true, bulk_export: true, ccda: true })
        assert_all_closed "the value is a Hash"
      end

      test "a Symbol closes every surface" do
        set_open :fhir_api
        assert_all_closed "the value is the bare Symbol :fhir_api"
      end

      # -- Unknown names --------------------------------------------------------

      test "an Array holding only unknown names opens nothing" do
        set_open [ :everything, "Patient", :chart ]
        assert_all_closed "the list holds only unknown names"
      end

      test "an unknown name beside a known one opens only the known one" do
        set_open [ :fhir_api, :bogus ]
        assert DisclosureSurfaces.open?(:fhir_api)
        refute DisclosureSurfaces.open?(:bulk_export), "an unknown entry must not open bulk_export"
        refute DisclosureSurfaces.open?(:ccda), "an unknown entry must not open ccda"
      end

      test "open? with a name that is not one of the three is false even when all three are open" do
        set_open ALL
        refute DisclosureSurfaces.open?(:html_chart)
        refute DisclosureSurfaces.open?(:metadata)
        refute DisclosureSurfaces.open?("Patient")
        refute DisclosureSurfaces.open?(:bogus)
        refute DisclosureSurfaces.open?(nil)
      end

      # -- Each surface opens only itself ---------------------------------------

      test "fhir_api alone opens only fhir_api" do
        set_open [ :fhir_api ]
        assert DisclosureSurfaces.open?(:fhir_api)
        refute DisclosureSurfaces.open?(:bulk_export)
        refute DisclosureSurfaces.open?(:ccda)
      end

      test "bulk_export alone opens only bulk_export" do
        set_open [ :bulk_export ]
        refute DisclosureSurfaces.open?(:fhir_api)
        assert DisclosureSurfaces.open?(:bulk_export)
        refute DisclosureSurfaces.open?(:ccda)
      end

      test "ccda alone opens only ccda" do
        set_open [ :ccda ]
        refute DisclosureSurfaces.open?(:fhir_api)
        refute DisclosureSurfaces.open?(:bulk_export)
        assert DisclosureSurfaces.open?(:ccda)
      end

      test "all three names open all three surfaces" do
        set_open ALL
        ALL.each { |name| assert DisclosureSurfaces.open?(name), "#{name} should be open" }
      end

      # -- Symbol / String equivalence -----------------------------------------

      test "String entries open the Symbol-named surface" do
        set_open [ "fhir_api" ]
        assert DisclosureSurfaces.open?(:fhir_api)
        refute DisclosureSurfaces.open?(:bulk_export)
      end

      test "Symbol entries answer a String query" do
        set_open [ :bulk_export ]
        assert DisclosureSurfaces.open?("bulk_export")
        refute DisclosureSurfaces.open?("fhir_api")
      end

      test "a mixed list of Strings and Symbols opens each named surface" do
        set_open [ "ccda", :fhir_api ]
        assert DisclosureSurfaces.open?(:ccda)
        assert DisclosureSurfaces.open?("fhir_api")
        refute DisclosureSurfaces.open?(:bulk_export)
      end

      # -- Read on every call, not cached ---------------------------------------

      test "the value is read on every call" do
        set_open [ :fhir_api ]
        assert DisclosureSurfaces.open?(:fhir_api)

        set_open nil
        refute DisclosureSurfaces.open?(:fhir_api), "closing the surface must take effect on the next call"

        set_open [ :ccda ]
        refute DisclosureSurfaces.open?(:fhir_api)
        assert DisclosureSurfaces.open?(:ccda)
      end
    end
  end
end
