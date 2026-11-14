# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #968: every disclosure surface is closed until the host opens it by name.
    class DisclosureSurfacesTest < ActiveSupport::TestCase
      ABSENT = Object.new.freeze

      setup { @saved_options = Rails.application.config.x.lakeraven_ehr }
      teardown { Rails.application.config.x.lakeraven_ehr = @saved_options }

      # [ label, configured value of the key, name asked, expected ]
      OPEN_ROWS = [
        [ "absent key",                      ABSENT,                   :bulk_export,  false ],
        [ "nil",                             nil,                      :bulk_export,  false ],
        [ "true",                            true,                     :bulk_export,  false ],
        [ "bare String",                     "bulk_export",            :bulk_export,  false ],
        [ "bare Symbol",                     :bulk_export,             :bulk_export,  false ],
        [ "Hash",                            { bulk_export: true },    :bulk_export,  false ],
        [ "empty Array",                     [],                       :bulk_export,  false ],
        [ "Array of unknown names",          %i[everything all],       :bulk_export,  false ],
        [ "Array of non-names",              [ 1, nil, true ],         :bulk_export,  false ],
        [ "Array nesting the name",          [ [ :bulk_export ] ],     :bulk_export,  false ],
        [ "Array naming other surfaces",     %i[fhir_api ccda],        :bulk_export,  false ],
        [ "unknown name, though configured", %i[unknown bulk_export],  :unknown,      false ],
        [ "nil name, though configured",     [ nil, :bulk_export ],    nil,           false ],
        [ "non-name argument",               %i[bulk_export],          [ :bulk_export ], false ],
        [ "named by Symbol",                 %i[bulk_export],          :bulk_export,  true ],
        [ "named by String",                 [ "bulk_export" ],        :bulk_export,  true ],
        [ "asked by String",                 %i[bulk_export],          "bulk_export", true ],
        [ "String entry, String argument",   [ "bulk_export" ],        "bulk_export", true ],
        [ "named among junk",                [ 1, nil, :bulk_export ], :bulk_export,  true ],
        [ "only the named one opens",        %i[bulk_export],          :fhir_api,     false ],
        [ "every name opened",               %i[fhir_api bulk_export ccda], :ccda,    true ]
      ].freeze

      OPEN_ROWS.each do |label, value, name, expected|
        test "open?(#{name.inspect}) is #{expected} with #{label}" do
          configure(value)
          assert_equal expected, DisclosureSurfaces.open?(name)
        end
      end

      # [ label, the whole config.x.lakeraven_ehr object, expected for :bulk_export ]
      OPTIONS_ROWS = [
        [ "Hash with a Symbol key",   { open_disclosure_surfaces: %i[bulk_export] },     true ],
        [ "Hash with a String key",   { "open_disclosure_surfaces" => %i[bulk_export] }, true ],
        [ "Hash without the key",     { other: %i[bulk_export] },                        false ],
        [ "Hash holding a bare name", { open_disclosure_surfaces: :bulk_export },        false ],
        [ "nil options",              nil,                                               false ],
        [ "String options",           "bulk_export",                                     false ],
        [ "Array options",            %i[bulk_export],                                   false ]
      ].freeze

      OPTIONS_ROWS.each do |label, options, expected|
        test "open?(:bulk_export) is #{expected} when the options object is a #{label}" do
          Rails.application.config.x.lakeraven_ehr = options
          assert_equal expected, DisclosureSurfaces.open?(:bulk_export)
        end
      end

      test "the names and the config key are the documented ones" do
        assert_equal %i[fhir_api bulk_export ccda], DisclosureSurfaces::NAMES
        assert_predicate DisclosureSurfaces::NAMES, :frozen?
        assert_equal :open_disclosure_surfaces, DisclosureSurfaces::KEY
      end

      test "config is read on every call" do
        configure(ABSENT)
        assert_not DisclosureSurfaces.open?(:bulk_export)
        configure(%i[bulk_export])
        assert DisclosureSurfaces.open?(:bulk_export)
        configure([])
        assert_not DisclosureSurfaces.open?(:bulk_export)
      end

      KNOWN_NAME_ROWS = [
        [ :bulk_export, :bulk_export ], [ "bulk_export", :bulk_export ], [ :fhir_api, :fhir_api ],
        [ "ccda", :ccda ], [ :unknown, nil ], [ "Bulk_Export", nil ], [ " bulk_export", nil ],
        [ "", nil ], [ nil, nil ], [ 1, nil ], [ true, nil ], [ [ :bulk_export ], nil ]
      ].freeze

      test "known_name answers the Symbol a value spells, else nil" do
        KNOWN_NAME_ROWS.each do |value, expected|
          actual = DisclosureSurfaces.known_name(value)
          expected.nil? ? assert_nil(actual, value.inspect) : assert_equal(expected, actual, value.inspect)
        end
      end

      private

      def configure(value)
        options = ActiveSupport::OrderedOptions.new
        options[:open_disclosure_surfaces] = value unless value.equal?(ABSENT)
        Rails.application.config.x.lakeraven_ehr = options
      end
    end
  end
end
