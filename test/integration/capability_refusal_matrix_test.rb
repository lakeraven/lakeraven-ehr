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
    "GET /scheduling" => "scheduling.open",
    "GET /scheduling/clinics/:id" => "scheduling.open",
    "GET /scheduling/clinics/:id/open_times" => "scheduling.open",
    "GET /scheduling/patients/:dfn/appointments" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/new" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/cancel" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/cancel" => "scheduling.open",
    "GET /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin" => "scheduling.open",
    "POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin" => "scheduling.open"
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
    verb == "GET" ? get(url) : post(url)
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
