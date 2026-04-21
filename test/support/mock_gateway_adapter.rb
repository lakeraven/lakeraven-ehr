# frozen_string_literal: true

require "singleton"
require "monitor"

# Mock Gateway Adapter — simulates RPMS RPC responses for tests.
# Responds to call_rpc with caret-delimited strings matching real RPC formats.
class MockGatewayAdapter
  include Singleton

  def initialize
    super
    @patients = {}
    @practitioners = {}
    @mutex = Monitor.new
    @seeded = false
  end

  def call_rpc(rpc_name, *params)
    ensure_seeded!
    raw = call_rpc_raw(rpc_name, *params)
    raw.to_s.split("\n").map { |line| line.delete("\r") }
  end

  def call_rpc_raw(rpc_name, *params)
    ensure_seeded!

    case rpc_name
    when "ORWPT SELECT"
      dfn = params[0].to_i
      p = @patients[dfn]
      return "" unless p
      age = p[:dob] ? ((Date.current - p[:dob]).to_i / 365) : ""
      "#{p[:name]}^#{p[:sex]}^#{format_date(p[:dob])}^#{p[:ssn]}^^^^^^^^^^^#{age}"

    when "ORWPT ID INFO"
      dfn = params[0].to_i
      p = @patients[dfn]
      return "" unless p
      "#{p[:name]}^#{p[:sex]}^#{format_date(p[:dob])}^#{p[:ssn]}^#{p[:race]}^#{p[:address_line1]}^#{p[:city]}^#{p[:state]}^#{p[:zip_code]}^#{p[:phone]}^#{p[:tribal_enrollment_number]}^#{p[:service_area]}^#{p[:coverage_type]}"

    when "ORWPT LIST ALL"
      pattern = params[0].to_s
      matching = @patients.select { |_dfn, p| name_matches?(p[:name], pattern) }
      matching.map { |dfn, p| "#{dfn}^#{p[:name]}" }.join("\r\n")

    when "ORWPT FULLSSN"
      ssn = params[0].to_s
      match = @patients.find { |_dfn, p| p[:ssn] == ssn }
      match ? "#{match[0]}^#{match[1][:name]}^^#{match[1][:ssn]}" : ""

    when "ORWU USERINFO"
      ien = params[0].to_i
      pr = @practitioners[ien]
      return "" unless pr
      "#{pr[:name]}^#{pr[:title]}^#{pr[:service_section]}^#{pr[:specialty]}^#{pr[:npi]}^#{pr[:dea_number]}^#{pr[:phone]}^#{pr[:provider_class]}"

    when "ORWU NEWPERS"
      pattern = params[0].to_s
      matching = @practitioners.select { |_ien, pr| name_matches?(pr[:name], pattern) }
      matching.map { |ien, pr| "#{ien}^#{pr[:name]}^#{pr[:title]}" }.join("\r\n")

    when "XUS SIGNON SETUP"
      "OK"

    else
      Rails.logger.warn("MockGatewayAdapter: Unknown RPC: #{rpc_name}") if defined?(Rails)
      ""
    end
  end

  private

  def ensure_seeded!
    return if @seeded
    @mutex.synchronize do
      return if @seeded
      seed_patients
      seed_practitioners
      @seeded = true
    end
  end

  def seed_patients
    @patients[1] = { name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15"), ssn: "111-11-1111",
                     race: "AMERICAN INDIAN", address_line1: "123 Main St", city: "Anchorage", state: "AK",
                     zip_code: "99501", phone: "907-555-1234", tribal_enrollment_number: "ANLC-12345",
                     service_area: "Anchorage", coverage_type: "IHS" }
    @patients[2] = { name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14"), ssn: "000009999",
                     race: "AMERICAN INDIAN", address_line1: "456 Disney Ave", city: "Orlando", state: "FL",
                     zip_code: "32801", phone: "555-5678", tribal_enrollment_number: "NN-67890",
                     service_area: "Arizona", coverage_type: "IHS/Medicaid" }
    @patients[3] = { name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25"), ssn: "555667777",
                     race: "AMERICAN INDIAN", tribal_enrollment_number: "CNO-24680",
                     service_area: "Oklahoma", coverage_type: "IHS" }
  end

  def seed_practitioners
    @practitioners[101] = { name: "MARTINEZ,SARAH", title: "MD", service_section: "Internal Medicine",
                            specialty: "Cardiology", npi: "1234567890", phone: "907-555-9999",
                            provider_class: "Physician" }
    @practitioners[102] = { name: "CHEN,JAMES", title: "DO", service_section: "Surgery",
                            specialty: "Orthopedic Surgery", npi: "2345678901", phone: "907-555-8888",
                            provider_class: "Physician" }
  end

  def name_matches?(name, pattern)
    return true if pattern.blank?
    name.to_s.upcase.start_with?(pattern.upcase)
  end

  def format_date(date)
    return "" unless date
    RpmsRpc::FilemanDateParser.format_date(date)
  end
end
