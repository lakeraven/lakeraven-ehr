# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # What every FHIR search on this server honours, in CapabilityStatement
      # shape.
      #
      # These are the declarations FHIRSearchBundle enforces, so a declared
      # capability and an enforced one cannot drift apart: a `_sort` or
      # `_include` value that is not listed here is refused with a 400. There
      # is no CapabilityStatement to put this in yet (#574): when /metadata
      # lands it renders `rest_search_params` into `rest[].searchParam`, which
      # is where FHIR R4 puts parameters common to every resource, and
      # `resource_capabilities(type)` into each `rest[].resource`.
      #
      # `search` lists the type's own search parameters: only the ones its
      # controller applies.
      module SearchCapabilities
        DEFAULT_COUNT = 20
        MAX_COUNT = 100

        # A sortable search parameter: where its value sits in the FHIR
        # resource, and how values compare. Several paths are compared in
        # order (a name sorts by family, then given).
        Sort = Data.define(:paths, :type)

        # A forward reference `_include` follows: where the reference sits in
        # the resource, and the one resource type it may point at.
        Include = Data.define(:paths, :target)

        # A resource's own search parameter: its FHIR search type, and what
        # this server does with it.
        Param = Data.define(:type, :documentation)

        ID = Sort.new(paths: [ %i[id] ], type: :string)
        NAME = Sort.new(paths: [ [ :name, 0, :family ], [ :name, 0, :given, 0 ] ], type: :string)
        STATUS = Sort.new(paths: [ %i[status] ], type: :string)
        SUBJECT = Include.new(paths: [ %i[subject reference] ], target: "Patient")
        PATIENT = Include.new(paths: [ %i[patient reference] ], target: "Patient")

        # Only what the resource the server builds actually carries.
        # Encounter, ServiceRequest and Procedure are not here: their entries
        # are the backend rows with a resourceType added, not FHIR elements a
        # search parameter could name. MeasureReport always returns an empty
        # Bundle.
        RESOURCES = {
          "Patient" => {
            sort: {
              "_id" => ID, "name" => NAME, "gender" => Sort.new(paths: [ %i[gender] ], type: :string),
              "birthdate" => Sort.new(paths: [ %i[birthDate] ], type: :date)
            }
          },
          "Practitioner" => { sort: { "_id" => ID, "name" => NAME } },
          "AllergyIntolerance" => {
            sort: { "_id" => ID },
            include: { "AllergyIntolerance:patient" => PATIENT }
          },
          "Condition" => {
            sort: { "_id" => ID },
            include: { "Condition:patient" => SUBJECT, "Condition:subject" => SUBJECT }
          },
          "MedicationRequest" => {
            search: {
              "status" => Param.new(
                type: "token",
                documentation: "Comma-separated status codes, any of which matches, mapped from the RPMS " \
                               "order status. A system|code value is refused with a 400 OperationOutcome."
              )
            },
            sort: { "_id" => ID, "status" => STATUS },
            include: { "MedicationRequest:patient" => SUBJECT, "MedicationRequest:subject" => SUBJECT }
          },
          "Observation" => {
            sort: {
              "_id" => ID, "status" => STATUS,
              "date" => Sort.new(paths: [ %i[effectiveDateTime] ], type: :date),
              "code" => Sort.new(paths: [ [ :code, :coding, 0, :code ] ], type: :string),
              "category" => Sort.new(paths: [ [ :category, 0, :coding, 0, :code ] ], type: :string)
            },
            include: { "Observation:patient" => SUBJECT, "Observation:subject" => SUBJECT }
          },
          "Immunization" => {
            sort: {
              "_id" => ID, "status" => STATUS,
              "date" => Sort.new(paths: [ %i[occurrenceDateTime] ], type: :date)
            },
            include: {
              "Immunization:patient" => PATIENT,
              "Immunization:performer" => Include.new(paths: [ [ :performer, :*, :actor, :reference ] ],
                                                      target: "Practitioner")
            }
          },
          "Consent" => {
            sort: {
              "_id" => ID, "status" => STATUS,
              "date" => Sort.new(paths: [ %i[dateTime] ], type: :date)
            },
            include: { "Consent:patient" => PATIENT }
          },
          # Sorted in the database, not on these paths: see
          # AuditEventsController::SORT_COLUMNS.
          "AuditEvent" => {
            sort: { "_id" => ID, "date" => Sort.new(paths: [ %i[recorded] ], type: :date) }
          },
          "Measure" => {
            sort: { "_id" => ID, "status" => STATUS, "title" => Sort.new(paths: [ %i[title] ], type: :string) }
          },
          "ValueSet" => {
            sort: {
              "_id" => ID, "status" => STATUS,
              "name" => Sort.new(paths: [ %i[name] ], type: :string),
              "title" => Sort.new(paths: [ %i[title] ], type: :string)
            }
          }
        }.freeze

        def self.sorts_for(type)
          RESOURCES.dig(type, :sort) || {}
        end

        def self.includes_for(type)
          RESOURCES.dig(type, :include) || {}
        end

        def self.search_params_for(type)
          RESOURCES.dig(type, :search) || {}
        end

        def self.rest_search_params
          [
            {
              name: "_count",
              type: "number",
              documentation: "Page size. Default #{DEFAULT_COUNT}, at most #{MAX_COUNT}. " \
                             "Any other value is refused with a 400 OperationOutcome."
            },
            {
              name: "_offset",
              type: "number",
              documentation: "Number of matches to skip before the page starts. Default 0. " \
                             "Bundle.link carries self, next and previous."
            },
            {
              name: "_sort",
              type: "string",
              documentation: "Comma-separated search parameters; prefix - for descending. " \
                             "Each resource lists the ones it sorts on. Any other value is " \
                             "refused with a 400 OperationOutcome."
            },
            {
              name: "_include",
              type: "string",
              documentation: "Forward references listed in each resource's searchInclude, " \
                             "for the matches on this page. Any other value is refused with " \
                             "a 400 OperationOutcome."
            }
          ]
        end

        # The search parts of a CapabilityStatement rest.resource entry: the
        # type's own parameters, its _sort parameters, and what _include may
        # follow.
        def self.resource_capabilities(type)
          sorts = sorts_for(type).keys
          params = search_params_for(type).map do |name, param|
            { name: name, type: param.type, documentation: param.documentation }
          end
          if sorts.any?
            params << {
              name: "_sort",
              type: "string",
              documentation: "Sorts on: #{sorts.join(', ')}. Prefix - for descending."
            }
          end

          capabilities = {}
          capabilities[:searchInclude] = includes_for(type).keys if includes_for(type).any?
          capabilities[:searchParam] = params if params.any?
          capabilities
        end
      end
    end
  end
end
