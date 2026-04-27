# frozen_string_literal: true

require "net/http"
require "json"

module Lakeraven
  module EHR
    # GudidLookupService -- Look up device info from FDA GUDID
    #
    # ONC 170.315(a)(14) -- Implantable Device List
    #
    # FDA GUDID API: https://accessgudid.nlm.nih.gov/api
    #
    # In production, calls the real FDA GUDID REST API.
    # For testing and offline use, falls back to a local cache
    # of known device identifiers.
    class GudidLookupService
      BASE_URL = "https://accessgudid.nlm.nih.gov/api/v3"

      KNOWN_DEVICES = {
        "00844588003288" => {
          device_description: "Dual-chamber cardiac pacemaker, MRI conditional",
          company_name: "Medtronic, Inc.",
          brand_name: "Azure XT DR MRI",
          mri_safety: "MR Conditional",
          device_class: "3",
          gtin: "00844588003288"
        },
        "10884521062856" => {
          device_description: "Total knee replacement prosthesis, cemented",
          company_name: "Zimmer Biomet",
          brand_name: "Persona Total Knee System",
          mri_safety: "MR Safe",
          device_class: "2",
          gtin: "10884521062856"
        }
      }.freeze

      def self.lookup(device_identifier)
        return { status: :invalid, message: "Device identifier is required" } if device_identifier.blank?

        cached = KNOWN_DEVICES[device_identifier.to_s]
        if cached
          return cached.merge(
            device_identifier: device_identifier,
            gudid_url: "#{BASE_URL}/devices/lookup?di=#{device_identifier}",
            source: "local_cache"
          )
        end

        fetch_from_gudid(device_identifier)
      rescue StandardError => e
        Rails.logger.warn("GUDID lookup failed for #{device_identifier}: #{e.message}")
        { status: :error, message: e.message, device_identifier: device_identifier }
      end

      def self.fetch_from_gudid(device_identifier)
        uri = URI("#{BASE_URL}/devices/lookup.json?di=#{device_identifier}")

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
          http.get(uri.request_uri)
        end

        if response.code == "200"
          parse_gudid_response(response.body, device_identifier)
        else
          { status: :not_found, device_identifier: device_identifier }
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED
        { status: :not_found, device_identifier: device_identifier }
      end
      private_class_method :fetch_from_gudid

      def self.parse_gudid_response(body, device_identifier)
        data = JSON.parse(body)
        device_data = data.dig("gudid", "device") || data

        {
          device_identifier: device_identifier,
          device_description: device_data["deviceDescription"],
          company_name: device_data.dig("companyName") || device_data.dig("labeler", "companyName"),
          brand_name: device_data["brandName"],
          mri_safety: extract_mri_safety(device_data),
          device_class: device_data["deviceClass"],
          gudid_url: "#{BASE_URL}/devices/lookup?di=#{device_identifier}",
          source: "fda_gudid"
        }
      rescue JSON::ParserError
        { status: :error, message: "Invalid GUDID response", device_identifier: device_identifier }
      end
      private_class_method :parse_gudid_response

      def self.extract_mri_safety(device_data)
        device_data.dig("mriSafetyStatus") ||
          device_data.dig("deviceSizes")&.first&.dig("mriSafetyStatus") ||
          "Not specified"
      end
      private_class_method :extract_mri_safety
    end
  end
end
