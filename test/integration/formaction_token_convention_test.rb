# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # A button that sends its form to another action (formaction) must not
    # post with the form's own token (#896). Per-form CSRF tokens bind that
    # token to the form's action and method, so Rails refuses it anywhere
    # else with a 422. The test environment runs with forgery protection off,
    # so no ordinary test meets the refusal; only a browser does.
    #
    # So, scanning the views: a formaction button either reads (formmethod
    # get, which needs no token) or is the shared lookup Find, which sends a
    # token of its own (shared/_lookup_search.html.erb). Turning forgery
    # protection on for the whole suite was tried: 251 tests that post
    # directly, without a page, fail, so the pages' own tests press their
    # buttons with BrowserFormHelper instead.
    class FormactionTokenConventionTest < ActiveSupport::TestCase
      ROOT = File.expand_path("../..", __dir__).freeze
      VIEWS = File.join(ROOT, "app", "views").freeze
      TOKEN_CARRIER = File.join(VIEWS, "lakeraven", "ehr", "shared", "_lookup_search.html.erb").freeze

      # An ERB tag or an HTML tag that names a formaction.
      FORMACTION_TAG = /<%=?(?:(?!%>).)*\bformaction\b(?:(?!%>).)*%>|<(?:button|input)\b[^>]*\bformaction\b[^>]*>/m
      READS = /\bformmethod(?::\s*|\s*=\s*)(?::get\b|["']get["'])/i

      def offences(source) = source.scan(FORMACTION_TAG).grep_v(READS)

      test "the matchers flag a formaction that posts and pass one that reads" do
        assert_equal 1, offences(%(<%= submit_tag "Find", formaction: find_path, formmethod: :post %>)).size
        assert_equal 1, offences(%(<%= submit_tag "Find",\n      formaction: find_path %>)).size
        assert_equal 1, offences(%(<button formaction="/find">Find</button>)).size
        assert_empty offences(%(<%= submit_tag "Show",\n      formaction: show_path,\n      formmethod: :get %>))
        assert_empty offences(%(<button formaction="/find" formmethod="get">Find</button>))
        assert_empty offences(%(<%= form_with url: x do |f| %>))
      end

      test "a button that posts its form to another action carries a token for that action" do
        found = Dir[File.join(VIEWS, "**", "*.erb")].reject { |path| path == TOKEN_CARRIER }.flat_map do |path|
          offences(File.read(path)).map { |tag| "#{path.delete_prefix("#{ROOT}/")}: #{tag.squish}" }
        end

        assert_empty found, "A formaction that posts sends the form's token, which fits only the form's own action. " \
          "Use lookup_field (or render shared/lookup_search), or read with formmethod: :get:\n#{found.join("\n")}"
      end
    end
  end
end
