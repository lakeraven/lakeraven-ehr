# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Seeded FHIR R4 test double (#599), answering read and search the way
      # Client does, with no HTTP. It replaces the mock rpms-rpc carried.
      #
      #   client = Lakeraven::EHR::FHIR::MockClient.new
      #   client.seed_resource("Patient", "1", {
      #     resourceType: "Patient", id: "1",
      #     name: [ { family: "Testpatient", given: [ "Ada" ] } ],
      #     gender: "female", birthDate: "1980-05-15"
      #   })
      #   Lakeraven::EHR.configuration.fhir_client = client
      #
      # Results have string keys at every level and are copies: changing one
      # never changes what was seeded.
      class MockClient
        def initialize
          @resources = {} # { "Patient" => { "1" => { "resourceType" => "Patient", ... } } }
        end

        # Seed one resource, replacing any already seeded under the same id.
        def seed_resource(resource_type, id, resource_hash)
          (@resources[resource_type.to_s] ||= {})[id.to_s] = deep_copy(resource_hash.to_h)
        end

        # The seeded resource, or a not-found OperationOutcome.
        def read(resource_type, id)
          resource = @resources.dig(resource_type.to_s, id.to_s)
          return operation_outcome("not-found", "#{resource_type}/#{id} not found") unless resource

          deep_copy(resource)
        end

        # A searchset Bundle of the resources every param matches. Supports
        # name (family prefix, or contained in "family given", ignoring case),
        # identifier, patient (Patient/<id> or bare id), _id, gender and
        # birthdate. Other params do not filter.
        def search(resource_type, params = {})
          candidates = @resources.fetch(resource_type.to_s, {}).values
          results = candidates.select do |resource|
            (params || {}).all? { |key, value| matches?(resource, key.to_s, value.to_s) }
          end
          bundle(results)
        end

        private

        def matches?(resource, key, value)
          case key
          when "name" then match_name(resource, value)
          when "identifier" then Array(resource["identifier"]).any? { |i| i["value"].to_s == value }
          when "patient" then match_patient(resource, value)
          when "_id" then resource["id"].to_s == value
          when "gender" then resource["gender"].to_s == value
          when "birthdate" then resource["birthDate"].to_s == value
          else true
          end
        end

        def match_name(resource, value)
          needle = value.upcase
          Array(resource["name"]).any? do |name|
            family = name["family"].to_s.upcase
            full = "#{family} #{Array(name['given']).join(' ').upcase}"
            family.start_with?(needle) || full.include?(needle)
          end
        end

        def match_patient(resource, value)
          reference = resource.dig("subject", "reference").to_s
          reference == "Patient/#{value}" || reference == value
        end

        def bundle(resources)
          {
            "resourceType" => "Bundle",
            "type" => "searchset",
            "total" => resources.length,
            "entry" => resources.map { |r| { "resource" => deep_copy(r) } }
          }
        end

        def operation_outcome(code, message)
          {
            "resourceType" => "OperationOutcome",
            "issue" => [ { "severity" => "error", "code" => code, "diagnostics" => message } ]
          }
        end

        def deep_copy(obj)
          case obj
          when Hash then obj.to_h { |k, v| [ k.to_s, deep_copy(v) ] }
          when Array then obj.map { |v| deep_copy(v) }
          when String then obj.dup
          else obj
          end
        end
      end
    end
  end
end
