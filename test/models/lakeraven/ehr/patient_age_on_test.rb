# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientAgeOnTest < ActiveSupport::TestCase
      test "age_on returns nil when dob is nil" do
        patient = Patient.new(dfn: 1)
        assert_nil patient.age_on(Date.new(2026, 10, 16))
      end

      test "age_on returns nil when dob is after the reference date" do
        patient = Patient.new(dfn: 1, dob: Date.new(2026, 12, 1))
        assert_nil patient.age_on(Date.new(2026, 10, 16))
      end

      test "age_on returns full years on the birthday" do
        patient = Patient.new(dfn: 1, dob: Date.new(1980, 5, 15))
        assert_equal 46, patient.age_on(Date.new(2026, 5, 15))
      end

      test "age_on returns one less than full years the day before the birthday" do
        patient = Patient.new(dfn: 1, dob: Date.new(1980, 5, 15))
        assert_equal 45, patient.age_on(Date.new(2026, 5, 14))
      end

      test "age_on for Feb 29 birth uses Mar 1 as birthday in non-leap years" do
        patient = Patient.new(dfn: 1, dob: Date.new(2000, 2, 29))
        assert_equal 25, patient.age_on(Date.new(2026, 2, 28))
        assert_equal 26, patient.age_on(Date.new(2026, 3, 1))
      end

      test "age_on returns zero when dob equals the reference date" do
        patient = Patient.new(dfn: 1, dob: Date.new(2020, 1, 1))
        assert_equal 0, patient.age_on(Date.new(2020, 1, 1))
      end
    end
  end
end
