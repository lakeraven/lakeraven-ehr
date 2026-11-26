# frozen_string_literal: true

require "test_helper"

# TerminologyGateway's own logic: which word it asks BSTS to complete, and
# which text it lets a search carry. What BSTS answers is proved live
# (features/terminology/diagnosis_search.feature) and in rpms-rpc.
module Lakeraven
  module EHR
    class TerminologyGatewayTest < ActiveSupport::TestCase
      class Recorder
        attr_reader :asked

        def type_ahead(word, max:)
          (@asked ||= []) << [ word, max ]
          []
        end
      end

      test "the words hint completes the last word typed" do
        recorder = Recorder.new
        TerminologyGateway.words_starting("major depress", via: recorder)

        assert_equal [ [ "depress", TerminologyGateway::WORD_LIMIT ] ], recorder.asked
      end

      test "blank text asks BSTS nothing" do
        recorder = Recorder.new

        assert_equal [], TerminologyGateway.words_starting("   ", via: recorder)
        assert_nil recorder.asked
      end

      test "a search carries no piece separator and stays short" do
        assert TerminologyGateway.searchable?("major depress")
        [ "", "  ", "a|b", "a^b", "x" * 81 ].each do |text|
          refute TerminologyGateway.searchable?(text), text.inspect
        end
      end
    end
  end
end
