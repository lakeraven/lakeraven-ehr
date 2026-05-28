# frozen_string_literal: true

require "test_helper"

# Regression test for Zeitwerk autoload of CcdaParser.
#
# CcdaParser used to live as an inner class inside ccda_generator.rb
# (a one-constant-per-file violation), so it only resolved if something
# had loaded ccda_generator.rb first. That made the controller test
# flaky depending on minitest's random seed.
module Lakeraven
  module EHR
    class CcdaParserAutoloadTest < ActiveSupport::TestCase
      test "CcdaParser is defined in its own file (Zeitwerk-friendly)" do
        # Inner-class nesting inside ccda_generator.rb made the constant
        # resolve only when something loaded the generator first — a
        # seed-dependent test flake. Pin the structural fix by checking
        # source_location.
        source_file, = Lakeraven::EHR::CcdaParser.instance_method(:parse).source_location
        assert source_file.end_with?("app/services/lakeraven/ehr/ccda_parser.rb"),
          "expected CcdaParser to live in its own file at " \
          "app/services/lakeraven/ehr/ccda_parser.rb (was #{source_file})"
      end

      test "CcdaParser.parse returns the expected document shape" do
        result = Lakeraven::EHR::CcdaParser.parse(<<~XML)
          <ClinicalDocument xmlns="urn:hl7-org:v3"/>
        XML

        assert_equal({ allergies: [], conditions: [], medications: [] }, result)
      end
    end
  end
end
