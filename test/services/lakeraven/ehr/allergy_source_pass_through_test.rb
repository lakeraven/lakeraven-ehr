# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The patient banner on non-chart pages reads allergies through
    # AllergySource.fetch (PatientBannerLoader#fetch_allergies). Before #579 a
    # raise in that read — RpmsSessions::SignInAgain included — came back as
    # a source with status :error, and the banner showed the patient with
    # allergies "not loaded". #579 must not change that for the banner: a
    # raise out of fetch reaches PatientBannerRendering's rescue, which
    # replaces the whole banner with the closed state.
    class AllergySourcePassThroughTest < ActiveSupport::TestCase
      # Synthetic. Stands in for detail an exception message can carry.
      MARKER = "SECRET-BROKER-DETAIL"

      test "fetch returns an error source, not a raise, when the read raises SignInAgain" do
        source = nil

        assert_nothing_raised do
          source = AllergySource.fetch(log_label: "[x]") { raise RpmsSessions::SignInAgain, MARKER }
        end

        assert_kind_of AllergySource, source
        assert_equal :error, source.status
        refute source.ok?
        assert_empty source.records
        refute source.verified_absence?, "a read that raised proves nothing about the patient's allergies"
      end

      test "fetch on a SignInAgain yields the not-loaded list status, never none recorded" do
        source = fetch_or_error { raise RpmsSessions::SignInAgain, MARKER }

        assert_kind_of AllergySource, source, "fetch raised instead of answering an error source"
        status = source.to_list_status(nil)
        assert_equal AllergyListStatus.not_loaded.state, status.state
        refute status.loaded?
        refute status.none_recorded?
      end

      test "fetch logs the class of a SignInAgain and never its message" do
        log = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)
        begin
          fetch_or_error { raise RpmsSessions::SignInAgain, MARKER }
        ensure
          Rails.logger = original
        end

        assert_includes log.string, "[x] allergy source"
        assert_includes log.string, "SignInAgain"
        refute_includes log.string, MARKER, "the exception message must not be logged"
      end

      private

      # The source fetch answered, or the error it raised.
      def fetch_or_error(&read)
        AllergySource.fetch(log_label: "[x]", &read)
      rescue StandardError => error
        error
      end
    end
  end
end
