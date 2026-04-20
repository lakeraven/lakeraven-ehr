# frozen_string_literal: true

# Mock Gateway Adapter for testing ActiveModel classes without RPMS/VistA RPC.
#
# Simulates core patient and practitioner RPCs for unit and BDD tests.
require "singleton"
require "monitor"

require_relative "mock_adapters/base_mock"
require_relative "mock_adapters/patient_mock"
require_relative "mock_adapters/practitioner_mock"

class MockGatewayAdapter
  include Singleton
  include MockAdapters::BaseMock
  include MockAdapters::PatientMock
  include MockAdapters::PractitionerMock

  def initialize
    super
    @created_patients = {}
    @created_practitioners = {}
    @clinical_data = {}
    @mutex = Monitor.new
    @seeded = false
  end

  def call_rpc(rpc_name, *params)
    ensure_seeded!
    raw_response = call_rpc_raw(rpc_name, *params)
    raw_response.to_s.split("\n").map { |line| line.delete("\r") }
  end

  def call_rpc_raw(rpc_name, *params)
    ensure_seeded!

    case rpc_name
    # Patient RPCs
    when "ORWPT SELECT"
      dfn = params[0].to_i
      patient = stored_patients[dfn]
      return "" unless patient
      age = patient[:dob] ? ((Date.current - patient[:dob]).to_i / 365) : ""
      "#{patient[:name]}^#{patient[:sex]}^#{format_rpms_date(patient[:dob])}^#{patient[:ssn]}^^^^^^^^^^^^#{age}"

    when "ORWPT ID INFO"
      dfn = params[0].to_i
      patient = stored_patients[dfn]
      return "" unless patient
      "#{patient[:name]}^#{patient[:sex]}^#{format_rpms_date(patient[:dob])}^#{patient[:ssn]}^#{patient[:race]}^#{patient[:address_line1]}^#{patient[:city]}^#{patient[:state]}^#{patient[:zip_code]}^#{patient[:phone]}^#{patient[:tribal_enrollment_number]}^#{patient[:service_area]}^#{patient[:coverage_type]}"

    when "ORWPT LIST ALL"
      name_pattern = params[0].to_s
      matching = stored_patients.select { |_dfn, patient| name_matches_pattern?(patient[:name], name_pattern) }
      matching.map { |dfn, patient| "#{dfn}^#{patient[:name]}" }.join("\r\n")

    when "ORWPT FULLSSN"
      ssn = params[0].to_s
      match = stored_patients.find { |_dfn, patient| patient[:ssn] == ssn }
      if match
        dfn, patient = match
        "#{dfn}^#{patient[:name]}^^#{patient[:ssn]}"
      else
        ""
      end

    # Patient Registration/Update RPCs
    when "BHDPTRPC REGISTER"
      fields = params[0].to_s.split("^")
      patient_data = {
        name: fields[0], dob: fields[1].present? ? Date.parse(fields[1]) : nil,
        sex: fields[2], ssn: fields[3], race: fields[4],
        address_line1: fields[5], city: fields[6], state: fields[7],
        zip_code: fields[8], phone: fields[9],
        tribal_enrollment_number: fields[10], service_area: fields[11],
        coverage_type: fields[12]
      }.compact
      result = register_new_patient(patient_data)
      result[:success] ? "1^#{result[:dfn]}" : "0^#{result[:error]}"

    when "BHDPTRPC UPDATE"
      dfn = params[0].to_i
      fields = params[1].to_s.split("^")
      changes = {
        name: fields[0], ssn: fields[1],
        dob: fields[2].present? ? Date.parse(fields[2]) : nil,
        sex: fields[3], address_line1: fields[4], city: fields[5],
        state: fields[6], zip_code: fields[7], phone: fields[8]
      }.compact
      result = update_patient(dfn, changes)
      result[:success] ? "1^" : "0^#{result[:error]}"

    # Practitioner RPCs
    when "ORWU USERINFO"
      ien = params[0].to_i
      practitioner = stored_practitioners[ien]
      return "" unless practitioner
      "#{practitioner[:name]}^#{practitioner[:title]}^#{practitioner[:service_section]}^#{practitioner[:specialty]}^#{practitioner[:npi]}^#{practitioner[:dea_number]}^#{practitioner[:phone]}^#{practitioner[:provider_class]}^#{practitioner[:service]}"

    when "ORWU NEWPERS"
      name_pattern = params[0].to_s
      matching = stored_practitioners.select { |_ien, prac| name_matches_pattern?(prac[:name], name_pattern) }
      matching.map { |ien, prac| "#{ien}^#{prac[:name]}^#{prac[:title]}" }.join("\r\n")

    # Tribal Enrollment RPCs
    when "BHDPTRPC TRIBAL"
      dfn = params[0].to_i
      patient = stored_patients[dfn]
      return "" unless patient
      enrollment_number = patient[:tribal_enrollment_number] || ""
      tribe_name = patient[:tribal_affiliation] || ""
      tribe_code = enrollment_number.split("-").first || ""
      status = enrollment_number.present? && enrollment_number.match?(/^[A-Z]+-\d+$/) ? "ACTIVE" : "INACTIVE"
      service_unit = patient[:service_area] || "Unknown"
      "#{enrollment_number}^#{tribe_name}^3200101^#{status}^#{service_unit}^#{tribe_code}"

    when "BHDPTRPC TRIBALVAL"
      enrollment_number = params[0].to_s
      if (match_data = enrollment_number.match(/^([A-Z]+)-(\d+)$/))
        tribe_code = match_data[1]
        number = match_data[2]
        "1^#{tribe_code}^#{number}^ACTIVE^Valid enrollment"
      else
        "0^^^INACTIVE^Enrollment not found or inactive"
      end

    when "BHDPTRPC TRIBELIST"
      tribe_identifier = params[0].to_s.upcase
      case tribe_identifier
      when "ANLC" then "100^Alaska Native - Anchorage (ANLC)^ANLC^Anchorage^Alaska^Alaska Area"
      when "NN" then "102^Navajo Nation^NN^Window Rock^Arizona^Navajo Area"
      when "CNO" then "103^Choctaw Nation of Oklahoma^CNO^Durant^Oklahoma^Oklahoma City Area"
      when "OST" then "104^Oglala Sioux Tribe^OST^Pine Ridge^South Dakota^Great Plains Area"
      when "EBCI" then "105^Eastern Band of Cherokee Indians^EBCI^Cherokee^North Carolina^Nashville Area"
      else ""
      end

    when "BHDPTRPC TRIBALELG"
      dfn = params[0].to_i
      patient = stored_patients[dfn]
      return "0^0^^^" unless patient
      enrollment_number = patient[:tribal_enrollment_number] || ""
      if enrollment_number.present? && enrollment_number.match?(/^[A-Z]+-\d+$/)
        service_unit = patient[:service_area] || "Unknown"
        "1^1^#{service_unit}^Eligible for IHS services^BASIC"
      else
        "0^0^^Enrollment inactive or not found^"
      end

    when "BHDPTRPC SU"
      dfn = params[0].to_i
      patient = stored_patients[dfn]
      return "" unless patient
      service_unit = patient[:service_area] || "Anchorage"
      "1^#{service_unit}^Alaska"

    # Clinical data RPCs (minimal stubs)
    when "ORQQAL LIST"
      "" # No allergies by default
    when "ORQQVI VITALS"
      "" # No vitals by default
    when "ORQQPL LIST"
      "" # No problems by default

    # Authentication RPCs
    when "XUS SIGNON SETUP"
      "OK"
    when "XUS AV CODE"
      "101\n0\n0\n\n\n3"

    else
      Rails.logger.warn("MockGatewayAdapter: Unknown RPC: #{rpc_name}") if defined?(Rails)
      ""
    end
  end
end
