# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The TIU title (#8925.1 IEN) a chart progress note is filed under (#1001).
    # It comes from PROGRESS_NOTE_TITLE_IEN when the configuration is built,
    # and only a string of digits naming a positive integer sets it. There is
    # no default title.
    class ProgressNoteTitleConfigurationTest < ActiveSupport::TestCase
      TITLE_ENV = "PROGRESS_NOTE_TITLE_IEN"

      setup do
        @title_env_was = ENV[TITLE_ENV]
      end

      teardown do
        @title_env_was.nil? ? ENV.delete(TITLE_ENV) : ENV[TITLE_ENV] = @title_env_was
        Lakeraven::EHR.reset_configuration!
      end

      def configuration_with(value)
        value.nil? ? ENV.delete(TITLE_ENV) : ENV[TITLE_ENV] = value
        Lakeraven::EHR::Configuration.new
      end

      def assert_reads_title!(configuration)
        assert_respond_to configuration, :progress_note_title_ien
      end

      test "the title is nil when the variable is not set" do
        configuration = configuration_with(nil)

        assert_reads_title!(configuration)
        assert_nil configuration.progress_note_title_ien
      end

      test "a string of digits sets the title, as an Integer" do
        configuration = configuration_with("1234")

        assert_reads_title!(configuration)
        assert_equal 1234, configuration.progress_note_title_ien
        assert_kind_of Integer, configuration.progress_note_title_ien
      end

      test "the engine's configuration reads the title when it is built" do
        ENV[TITLE_ENV] = "88"
        Lakeraven::EHR.reset_configuration!

        assert_reads_title!(Lakeraven::EHR.configuration)
        assert_equal 88, Lakeraven::EHR.configuration.progress_note_title_ien
      end

      test "the title is read when the configuration is built, not afterwards" do
        configuration = configuration_with("1234")
        ENV[TITLE_ENV] = "5678"

        assert_reads_title!(configuration)
        assert_equal 1234, configuration.progress_note_title_ien
      end

      {
        "blank" => "",
        "whitespace" => "   ",
        "zero" => "0",
        "zeros" => "000",
        "letters" => "abc",
        "a negative number" => "-3",
        "digits followed by a letter" => "12x",
        "a letter followed by digits" => "x12",
        "a decimal" => "12.5",
        "a signed number" => "+12",
        "digits around a space" => "1 2",
        "digits on a second line" => "abc\n12",
        "digits before a second line" => "12\nabc"
      }.each do |description, value|
        test "#{description} leaves the title nil" do
          configuration = configuration_with(value)

          assert_reads_title!(configuration)
          assert_nil configuration.progress_note_title_ien, value.inspect
        end
      end
    end
  end
end
