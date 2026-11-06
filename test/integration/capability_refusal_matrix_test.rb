# frozen_string_literal: true

require "test_helper"
require_relative "../support/demo_persona_keys"

# Every registration and scheduling screen is refused on the server to a demo
# persona without the capability it needs, and not refused to one with it
# (ADR 0010). The check runs before any RPMS read, so a refusal needs no RPMS;
# an allowed request may go on to answer anything but 403. A route with no row
# here fails, so a new screen cannot ship ungated.
class CapabilityRefusalMatrixTest < ActionDispatch::IntegrationTest
  ROUTES = {
    "GET /registration/patients" => "registration.search",
    "GET /registration/patients/new" => "patient.register",
    "POST /registration/patients/new" => "patient.register",
    "POST /registration/patients/search" => "registration.search",
    "POST /registration/patients" => "patient.register",
    "POST /registration/patients/confirm" => "patient.register",
    "GET /registration/patients/:dfn" => "registration.view",
    "GET /registration/patients/:dfn/demographics/edit" => "patient.register",
    "PATCH /registration/patients/:dfn/demographics" => "patient.register",
    "GET /registration/patients/:dfn/address/edit" => "patient.register",
    "PATCH /registration/patients/:dfn/address" => "patient.register",
    "GET /registration/patients/:dfn/contacts/:kind/edit" => "patient.register",
    "POST /registration/patients/:dfn/contacts/:kind/edit" => "patient.register",
    "POST /registration/patients/:dfn/contacts/:kind" => "patient.register",
    "GET /registration/patients/:dfn/languages/edit" => "patient.register",
    "POST /registration/patients/:dfn/languages/edit" => "patient.register",
    "POST /registration/patients/:dfn/languages" => "patient.register",
    "GET /registration/patients/:dfn/social_status/edit" => "patient.register",
    "POST /registration/patients/:dfn/social_status" => "patient.register",
    "GET /registration/patients/:dfn/other_names" => "registration.view",
    "POST /registration/patients/:dfn/other_names" => "patient.register",
    "POST /registration/patients/:dfn/other_names/:ien/remove" => "patient.register",
    "GET /registration/patients/:dfn/preferred_name/edit" => "patient.register",
    "POST /registration/patients/:dfn/preferred_name" => "patient.register",
    "GET /registration/patients/:dfn/race_ethnicity/edit" => "patient.register",
    "POST /registration/patients/:dfn/race_ethnicity" => "patient.register",
    "GET /registration/patients/:dfn/applications/new" => "patient.register",
    "POST /registration/patients/:dfn/applications" => "patient.register",
    "POST /registration/patients/:dfn/applications/:ien/status" => "patient.register",
    "GET /registration/patients/:dfn/eligibility/edit" => "patient.register",
    "PATCH /registration/patients/:dfn/eligibility" => "patient.register",
    "GET /registration/patients/:dfn/coverage" => "registration.view",
    "GET /registration/patients/:dfn/coverage/new" => "patient.register",
    "POST /registration/patients/:dfn/coverage/new" => "patient.register",
    "POST /registration/patients/:dfn/coverage" => "patient.register",
    "GET /scheduling" => "scheduling.open",
    "GET /scheduling/clinics/:id" => "scheduling.open",
    "GET /scheduling/clinics/:id/week" => "scheduling.open",
    "GET /scheduling/needing_action" => "scheduling.open",
    "GET /scheduling/appointments" => "scheduling.open",
    "GET /scheduling/clinics/:id/open_times" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/wait_list" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/wait_list" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/wait_list/new" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/wait_list/:entry_id/edit" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/wait_list/:entry_id" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/wait_list/:entry_id/removal" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/wait_list/:entry_id/removal" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/wait_list/:entry_id/booking" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/wait_list/:entry_id/booking" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/hours/new" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/hours" => "scheduling.open",
    "GET /scheduling/patients/:dfn/appointments" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/new" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/registrations/new" => "patient.quick_register",
    "POST /scheduling/clinics/:resource_id/registrations" => "patient.quick_register",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/cancel" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/cancel" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/reschedule" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/reschedule" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/details" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/details" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/walk_ins/new" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/walk_ins/find" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/walk_ins" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/checkout" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkout" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkout/undo" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin/undo" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/no_show" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/no_show/undo" => "scheduling.open"
  }.freeze

  def engine_routes
    Lakeraven::EHR::Engine.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      "#{route.verb} #{path}" if path.match?(%r{\A/(registration|scheduling)(/|\z)})
    end
  end

  def sign_in_as(persona)
    keys = Lakeraven::EHR::Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA.fetch(persona)).map(&:to_s)
    post "/lakeraven-ehr/test_session", params: { duz: "200", user_type: "user", user_name: persona, security_keys: keys.join(",") }
  end

  def request_route(route)
    verb, path = route.split(" ", 2)
    url = "/lakeraven-ehr#{path.gsub(/:\w+/, '3')}"
    public_send(verb.downcase, url)
  end

  test "every registration and scheduling route has a row" do
    assert_equal engine_routes.sort, ROUTES.keys.sort
  end

  DemoPersonaKeys::BY_PERSONA.each_key do |persona|
    test "#{persona} is refused exactly the screens it lacks the capability for" do
      held = Lakeraven::EHR::Capabilities.for(Lakeraven::EHR::Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA[persona]))
      sign_in_as(persona)
      ROUTES.each do |route, capability|
        request_route(route)
        if held.include?(capability)
          refute_equal 403, response.status, "#{persona} holds #{capability}: #{route}"
        else
          assert_equal 403, response.status, "#{persona} lacks #{capability}: #{route}"
        end
      end
    end
  end
end
