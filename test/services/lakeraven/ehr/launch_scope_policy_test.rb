# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # A launch grants what the app asked for, within its registration, within
    # what the signed-in user's own RPMS access allows (#839, ADR 0010).
    class LaunchScopePolicyTest < ActiveSupport::TestCase
      USER = "user/Patient.rs user/Observation.rs user/Encounter.cruds"

      def granted(requested, registered: "user/*.cruds", user: USER)
        LaunchScopePolicy.new(requested: requested, registered: registered, user_scopes: user).granted
      end

      test "a request within the registration and the user's access is granted" do
        assert_equal %w[user/Observation.rs user/Patient.rs], granted("user/Patient.rs user/Observation.rs")
      end

      test "nothing beyond what the user holds" do
        assert_equal [], granted("user/Condition.rs")
        assert_equal %w[user/Patient.rs], granted("user/Patient.cruds")
      end

      test "nothing beyond the client's registration" do
        assert_equal %w[user/Encounter.rs], granted("user/Encounter.cruds", registered: "user/*.rs")
        assert_equal [], granted("user/Patient.rs", registered: "user/Observation.rs")
      end

      test "a wildcard request is granted as the user's own types, never as a wildcard" do
        assert_equal %w[user/Encounter.rs user/Observation.rs user/Patient.rs], granted("user/*.rs")
      end

      test "v1 scopes come back in v2" do
        assert_equal %w[user/Patient.rs], granted("user/Patient.read")
      end

      test "only the contexts asked for: patient/ waits for a patient" do
        assert_equal [], granted("patient/Patient.rs", registered: "patient/*.rs")
        assert_equal %w[patient/Patient.rs],
          LaunchScopePolicy.new(requested: "patient/Patient.read", registered: "patient/*.rs",
                                user_scopes: USER, contexts: %w[patient]).granted
      end

      test "scopes it does not understand are dropped" do
        assert_equal [], granted("openid fhirUser offline_access system/*.rs user/Observation.rs?category=vital-signs")
      end
    end

    class ScopeDescriptionTest < ActiveSupport::TestCase
      test "says what the app may do in plain words" do
        assert_equal "See patients' allergies", ScopeDescription.for("user/AllergyIntolerance.rs")
        assert_equal "See this patient's medication orders", ScopeDescription.for("patient/MedicationRequest.rs")
        assert_equal "See, add, change and remove patients' visits", ScopeDescription.for("user/Encounter.cruds")
        assert_equal "See providers' names", ScopeDescription.for("user/Practitioner.rs")
      end
    end
  end
end
