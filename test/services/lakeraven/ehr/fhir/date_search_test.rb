# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      # R4's date search table, read as ranges: a value is as wide as its
      # precision, so the same date can be inside one value and overlap another.
      class DateSearchTest < ActiveSupport::TestCase
        def matches?(value, served)
          DateSearch.parse(value).matches?(DateSearch.served_range(served))
        end

        test "eq holds a date inside the value's whole precision" do
          assert matches?("2024", "2024-03-15")
          assert matches?("2024-03", "2024-03-15T10:00:00Z")
          assert matches?("2024-03-15", "2024-03-15")
          refute matches?("2024-03-15", "2024")
          refute matches?("2024-04", "2024-03-15")
        end

        test "no prefix means eq, and ne is its opposite" do
          assert matches?("eq2024-03", "2024-03-15")
          refute matches?("ne2024-03", "2024-03-15")
          assert matches?("ne2024-04", "2024-03-15")
        end

        test "gt and lt need a part of the date beyond the value" do
          assert matches?("gt2024-03-14", "2024-03-15")
          refute matches?("gt2024-03-15", "2024-03-15")
          assert matches?("lt2024-03-16", "2024-03-15")
          refute matches?("lt2024-03-15", "2024-03-15")
        end

        test "ge and le also take the value itself" do
          assert matches?("ge2024-03-15", "2024-03-15")
          refute matches?("ge2024-03-16", "2024-03-15")
          assert matches?("le2024-03-15", "2024-03-15")
          refute matches?("le2024-03-14", "2024-03-15")
        end

        test "a Period that straddles the value is above it and below it, and not within it" do
          period = { start: "2024-03-01", end: "2024-03-31" }

          assert matches?("gt2024-03-15", period)
          assert matches?("lt2024-03-15", period)
          refute matches?("2024-03-15", period)
          assert matches?("2024-03", period)
        end

        test "sa and eb need the whole date clear of the value" do
          period = { start: "2024-03-01", end: "2024-03-31" }

          assert matches?("sa2024-02", period)
          refute matches?("sa2024-03-15", period)
          assert matches?("eb2024-04", period)
          refute matches?("eb2024-03-15", period)
        end

        test "an open Period runs on past any later date" do
          period = { "start" => "2024-03-01" }

          assert matches?("gt2030", period)
          refute matches?("eb2030", period)
        end

        test "a time zone on the value is honoured" do
          assert matches?("eq2024-03-15T10:00:00-08:00", "2024-03-15T18:00:00Z")
          refute matches?("eq2024-03-15T10:00:00Z", "2024-03-15T18:00:00Z")
        end

        test "what is not a date parses to nothing" do
          [ "", "soon", "2024-13", "2024-02-30", "ap2024", "ge", "2024-03-15T10", "20240315" ].each do |value|
            assert_nil DateSearch.parse(value), value.inspect
          end
        end

        test "a value with nothing to compare has no served range" do
          assert_nil DateSearch.served_range(nil)
          assert_nil DateSearch.served_range({})
        end
      end
    end
  end
end
