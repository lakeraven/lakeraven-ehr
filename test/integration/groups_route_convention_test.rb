# frozen_string_literal: true

require "test_helper"

# Pins routing and controller wiring expected of a new FHIR read endpoint (#216).
# Group read is also declared in the CapabilityStatement and wired in
# FhirReadEgressTest (WIRED_ACTIONS / WIRED_ENDPOINTS).
class GroupsRouteConventionTest < ActiveSupport::TestCase
  MOUNT = "/lakeraven-ehr"
  SAMPLE_GROUP_ID = "cohort-synthetic-a"

  test "GET /Group/:id is routed to GroupsController#show" do
    route = Rails.application.routes.recognize_path(
      "#{MOUNT}/Group/#{SAMPLE_GROUP_ID}",
      method: :get
    )

    assert_equal "lakeraven/ehr/groups", route[:controller]
    assert_equal "show", route[:action]
    assert_equal SAMPLE_GROUP_ID, route[:id]
  end

  test "GroupsController is defined under Lakeraven::EHR" do
    assert_kind_of Class, Lakeraven::EHR::GroupsController
    assert Lakeraven::EHR::GroupsController < Lakeraven::EHR::ApplicationController
  end
end
