# frozen_string_literal: true

require "test_helper"
require_relative "../support/url_patient_context_test_helper"

# When the chart cannot be read, the page that says so renders in the app
# layout like the chart itself (#1110): the header, the main nav and the
# patient search, so the clinician can move on without the back button.
class ChartUnavailableLayoutTest < ActionDispatch::IntegrationTest
  include UrlPatientContextTestHelper

  setup { enable_forgery_protection! }

  teardown do
    restore_forgery_protection!
    teardown_oauth!
  end

  test "the chart-unavailable page has the app's header and main nav" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)

      with_patient_repository_raising { get_chart_for_dfn!(1) }

      assert_response :service_unavailable
      assert_select "header nav[aria-label='Main']"
      assert_select "header a", text: Lakeraven::EHR.configuration.product_name
      assert_select "header button", text: "Sign out"
      assert_select "main [role=alert]", text: /This chart could not be loaded/
      assert_empty_banner!
    end
  end

  test "the chart-unavailable page has a title of its own and one heading" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)

      with_patient_repository_raising { get_chart_for_dfn!(1) }

      assert_select "title", text: /\AChart unavailable \| /
      assert_select "h1", count: 1
    end
  end
end
