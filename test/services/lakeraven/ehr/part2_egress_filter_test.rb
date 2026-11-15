# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # 42 CFR § 2.32: a redisclosure of received Part 2 data carries the
    # notice. Part2EgressFilter is the one egress seam, so these tests pin
    # what it does to a Part 2-labelled payload of every shape it receives.
    # All data here is synthetic.
    class Part2EgressFilterTest < ActiveSupport::TestCase
      ACT_CODE = "http://terminology.hl7.org/CodeSystem/v3-ActCode"
      PART2_LABEL = { "system" => ACT_CODE, "code" => "42CFRPart2" }.freeze
      UNRELATED_LABEL = { "system" => "http://terminology.hl7.org/CodeSystem/v3-Confidentiality", "code" => "N" }.freeze

      # --- the notice constants -------------------------------------------

      test "notice TEXT is the 2.32(a)(1) statement" do
        text = Part2RedisclosureNotice::TEXT

        assert text.start_with?(
          "This record which has been disclosed to you is protected by Federal confidentiality rules (42 CFR part 2)."
        ), "TEXT must open with the 2.32(a)(1) statement"
        assert_includes text, "42 CFR 2.31"
      end

      test "notice constants name the extension, the refrain policy and the Part 2 codes" do
        assert_equal "https://lakeraven.com/fhir/StructureDefinition/part2-redisclosure-notice",
          Part2RedisclosureNotice::EXTENSION_URL
        assert_equal({ "system" => ACT_CODE, "code" => "NORDSCLCD" }, Part2RedisclosureNotice::REFRAIN)
        assert_equal %w[42CFRPart2 ETH SUD], Part2RedisclosureNotice::PART2_CODES
      end

      # --- rule 1: unlabelled input is returned equal ----------------------

      test "unlabelled resource with string keys is returned equal and not noticed" do
        resource = condition("meta" => { "security" => [ UNRELATED_LABEL ] })

        result = Part2EgressFilter.call(resource)

        assert_equal resource, result
        refute_noticed result
      end

      test "unlabelled resource with symbol keys is returned equal and not noticed" do
        resource = { resourceType: "Condition", id: "syn-1", meta: { versionId: "1" } }

        result = Part2EgressFilter.call(resource)

        assert_equal resource, result
        refute_noticed result
      end

      test "unlabelled resource with no meta is returned equal" do
        resource = { "resourceType" => "Basic", "id" => "syn-basic" }

        assert_equal resource, Part2EgressFilter.call(resource)
      end

      test "unlabelled Bundle is returned equal and gets no notice" do
        bundle = bundle_of(
          entry(condition, mode: "match"),
          entry({ "resourceType" => "Patient", "id" => "syn-pt" }, mode: "include")
        )

        result = Part2EgressFilter.call(bundle)

        assert_equal bundle, result
        refute_noticed result
        result["entry"].each { |e| refute_noticed e["resource"] }
      end

      test "unlabelled symbol-keyed Bundle is returned equal" do
        bundle = {
          resourceType: "Bundle", type: "searchset",
          entry: [ { resource: { resourceType: "Condition", id: "syn-1" }, search: { mode: "match" } } ]
        }

        assert_equal bundle, Part2EgressFilter.call(bundle)
      end

      test "unlabelled export Strings are returned equal" do
        ndjson = "#{condition.to_json}\n#{{ 'resourceType' => 'Patient', 'id' => 'syn-pt' }.to_json}\n"
        csv = "id,event_type,action\n1,rest,R\n"
        json = { "export" => "synthetic", "files" => [] }.to_json

        [ ndjson, csv, json, "" ].each do |text|
          assert_equal text, Part2EgressFilter.call(text)
        end
      end

      test "unlabelled C-CDA sections are returned equal" do
        sections = ccda_sections

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      test "a clinical coding outside meta.security is not a Part 2 label" do
        # The rule keys on code values in meta.security (or under a security
        # key), not on any element that happens to hold the same string.
        resource = condition("code" => { "coding" => [ { "system" => "http://example.test/synthetic", "code" => "ETH" } ] })

        result = Part2EgressFilter.call(resource)

        assert_equal resource, result
        refute_noticed result
      end

      # --- rule 2: a labelled resource comes back noticed -------------------

      test "labelled top-level resource is noticed and every other element is unchanged" do
        resource = condition(
          "meta" => { "versionId" => "3", "security" => [ UNRELATED_LABEL, PART2_LABEL ], "tag" => [ { "code" => "syn" } ] }
        )

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_equal resource, without_notice(result)
      end

      test "labelled symbol-keyed resource is noticed and every other element is unchanged" do
        resource = {
          resourceType: "Condition", id: "syn-1",
          code: { text: "Synthetic condition" },
          meta: { security: [ { system: ACT_CODE, code: "42CFRPart2" } ] }
        }

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_equal resource.deep_stringify_keys, without_notice(result)
      end

      %w[42CFRPart2 ETH SUD].each do |code|
        test "a meta.security code of #{code} with no system counts as Part 2" do
          resource = condition("meta" => { "security" => [ { "code" => code } ] })

          result = Part2EgressFilter.call(resource)

          assert_noticed result
          assert_equal resource, without_notice(result)
        end
      end

      test "every labelled entry of a Bundle is noticed, match and include alike" do
        labelled_match = condition("id" => "syn-match", "meta" => { "security" => [ PART2_LABEL ] })
        plain_match = condition("id" => "syn-plain")
        labelled_include = { "resourceType" => "Observation", "id" => "syn-inc", "meta" => { "security" => [ { "code" => "SUD" } ] } }
        plain_include = { "resourceType" => "Patient", "id" => "syn-pt" }
        bundle = bundle_of(
          entry(labelled_match, mode: "match"), entry(plain_match, mode: "match"),
          entry(labelled_include, mode: "include"), entry(plain_include, mode: "include")
        )

        result = Part2EgressFilter.call(bundle)
        resources = result["entry"].map { |e| e["resource"] }

        assert_equal 4, resources.size
        assert_noticed resources[0]
        assert_equal labelled_match, without_notice(resources[0])
        assert_equal plain_match, resources[1]
        refute_noticed resources[1]
        assert_noticed resources[2]
        assert_equal labelled_include, without_notice(resources[2])
        assert_equal plain_include, resources[3]
        refute_noticed resources[3]
        assert_equal bundle["entry"].map { |e| e.except("resource") }, result["entry"].map { |e| e.except("resource") }
      end

      test "labelled entry of a symbol-keyed Bundle is noticed" do
        bundle = {
          resourceType: "Bundle", type: "searchset",
          entry: [
            { resource: { resourceType: "Condition", id: "syn-1", meta: { security: [ { code: "42CFRPart2" } ] } },
              search: { mode: "match" } }
          ]
        }

        result = Part2EgressFilter.call(bundle).deep_stringify_keys

        assert_noticed result["entry"][0]["resource"]
        assert_noticed result
      end

      test "a labelled resource in another resource's contained is noticed" do
        contained = { "resourceType" => "Observation", "id" => "syn-contained", "meta" => { "security" => [ PART2_LABEL ] } }
        plain_contained = { "resourceType" => "Practitioner", "id" => "syn-pr" }
        resource = condition("contained" => [ contained, plain_contained ])

        result = Part2EgressFilter.call(resource)

        assert_noticed result["contained"][0]
        assert_equal contained, without_notice(result["contained"][0])
        assert_equal plain_contained, result["contained"][1]
        assert_equal resource.except("contained", "meta"), result.except("contained", "meta")
      end

      # --- rule 3: the Bundle itself carries the notice ---------------------

      test "a Bundle with a labelled match entry is itself noticed" do
        bundle = bundle_of(entry(condition("meta" => { "security" => [ PART2_LABEL ] }), mode: "match"))

        result = Part2EgressFilter.call(bundle)

        assert_noticed result
        assert_equal bundle.except("entry"), without_notice(result).except("entry")
      end

      test "a Bundle whose only labelled resource is an include entry is itself noticed" do
        bundle = bundle_of(
          entry(condition, mode: "match"),
          entry({ "resourceType" => "Observation", "id" => "syn-inc", "meta" => { "security" => [ { "code" => "ETH" } ] } }, mode: "include")
        )

        assert_noticed Part2EgressFilter.call(bundle)
      end

      test "a Bundle whose only labelled resource is contained in an entry is itself noticed" do
        contained = { "resourceType" => "Observation", "id" => "syn-contained", "meta" => { "security" => [ PART2_LABEL ] } }
        bundle = bundle_of(entry(condition("contained" => [ contained ]), mode: "match"))

        result = Part2EgressFilter.call(bundle)

        assert_noticed result
        assert_noticed result["entry"][0]["resource"]["contained"][0]
      end

      test "a noticed Bundle keeps its existing meta" do
        bundle = bundle_of(entry(condition("meta" => { "security" => [ PART2_LABEL ] }), mode: "match"))
          .merge("meta" => { "lastUpdated" => "2026-01-01T00:00:00Z", "security" => [ UNRELATED_LABEL ] })

        result = Part2EgressFilter.call(bundle)

        assert_noticed result
        assert_equal bundle["meta"], without_notice(result)["meta"]
      end

      # --- rule 4: NDJSON ---------------------------------------------------

      test "labelled NDJSON lines are noticed and other lines are byte-for-byte unchanged" do
        labelled = condition("id" => "syn-labelled", "meta" => { "security" => [ PART2_LABEL ] })
        plain_line = %({ "resourceType" : "Condition",  "id":"syn-spaced" })
        other_line = { "resourceType" => "Patient", "id" => "syn-pt" }.to_json
        ndjson = "#{plain_line}\n#{labelled.to_json}\n#{other_line}\n"

        result = Part2EgressFilter.call(ndjson)

        assert_kind_of String, result
        assert result.end_with?("\n"), "trailing newline must be preserved"
        lines = result.split("\n", -1)
        assert_equal 4, lines.size, "one line per input line, plus the trailing newline"
        assert_equal plain_line, lines[0]
        assert_equal other_line, lines[2]
        assert_equal "", lines[3]
        noticed = JSON.parse(lines[1])
        assert_noticed noticed
        assert_equal labelled, without_notice(noticed)
      end

      test "NDJSON without a trailing newline does not gain one" do
        labelled = condition("meta" => { "security" => [ { "code" => "SUD" } ] })
        last_line = { "resourceType" => "Patient", "id" => "syn-pt" }.to_json
        ndjson = "#{labelled.to_json}\n#{last_line}"

        result = Part2EgressFilter.call(ndjson)

        lines = result.split("\n", -1)
        assert_equal 2, lines.size
        assert_noticed JSON.parse(lines[0])
        assert_equal last_line, lines[1]
      end

      # --- rule 5: idempotent -----------------------------------------------

      test "filtering a noticed resource again returns an equal value" do
        once = Part2EgressFilter.call(condition("meta" => { "security" => [ PART2_LABEL ] }))
        twice = Part2EgressFilter.call(once)

        assert_noticed once
        assert_equal once, twice
        assert_equal 1, refrain_count(twice)
        assert_equal 1, notice_count(twice)
      end

      test "filtering a noticed Bundle again returns an equal value" do
        bundle = bundle_of(
          entry(condition("meta" => { "security" => [ PART2_LABEL ] }), mode: "match"),
          entry({ "resourceType" => "Patient", "id" => "syn-pt" }, mode: "include")
        )
        once = Part2EgressFilter.call(bundle)
        twice = Part2EgressFilter.call(once)

        assert_noticed once
        assert_equal once, twice
        assert_equal 1, refrain_count(twice)
        assert_equal 1, notice_count(twice)
        assert_equal 1, refrain_count(twice["entry"][0]["resource"])
        assert_equal 1, notice_count(twice["entry"][0]["resource"])
      end

      test "filtering noticed NDJSON again returns an equal String" do
        ndjson = "#{condition('meta' => { 'security' => [ PART2_LABEL ] }).to_json}\n"
        once = Part2EgressFilter.call(ndjson)
        twice = Part2EgressFilter.call(once)

        assert_noticed JSON.parse(once.lines.first)
        assert_equal once, twice
      end

      test "a labelled resource that already has REFRAIN gets the notice once and no second REFRAIN" do
        resource = condition(
          "meta" => { "security" => [ PART2_LABEL, { "system" => ACT_CODE, "code" => "NORDSCLCD" } ] }
        )

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_equal 1, refrain_count(result)
        assert_equal 1, notice_count(result)
        assert_equal resource["meta"]["security"], result["meta"]["security"]
      end

      test "a labelled resource keeps its other meta.extension entries" do
        other = { "url" => "https://example.test/fhir/StructureDefinition/synthetic", "valueString" => "x" }
        resource = condition("meta" => { "security" => [ PART2_LABEL ], "extension" => [ other ] })

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_includes result["meta"]["extension"], other
        assert_equal 2, result["meta"]["extension"].size
      end

      # --- rule 6: the caller's input is never mutated ----------------------

      test "the input is not mutated for any payload shape" do
        labelled = condition("meta" => { "security" => [ PART2_LABEL ] })
        inputs = [
          labelled,
          { resourceType: "Condition", id: "syn-1", meta: { security: [ { code: "ETH" } ] } },
          bundle_of(entry(labelled, mode: "match"), entry(condition("contained" => [ labelled ]), mode: "include")),
          "#{labelled.to_json}\n",
          ccda_sections,
          ccda_sections(conditions: [ { code: "F10.20", display: "Synthetic", security: [ { code: "42CFRPart2" } ] } ])
        ]

        inputs.each do |input|
          before = Marshal.load(Marshal.dump(input))

          Part2EgressFilter.call(input)

          assert_equal before, input, "filter mutated its input: #{before.inspect[0, 80]}"
        end
      end

      test "the noticed result does not share meta with the input" do
        resource = condition("meta" => { "security" => [ PART2_LABEL ] })

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        refute_same resource["meta"]["security"], result["meta"]["security"]
        assert_equal [ PART2_LABEL ], resource["meta"]["security"]
        refute resource["meta"].key?("extension")
      end

      # --- rule 7: fail closed ----------------------------------------------

      test "labelled resource whose meta is not a Hash is refused" do
        resource = condition("meta" => [ { "security" => [ PART2_LABEL ] } ])

        assert_nil Part2EgressFilter.call(resource)
      end

      test "labelled resource whose meta.security is not an Array is refused" do
        resource = condition("meta" => { "security" => { "code" => "42CFRPart2" } })

        assert_nil Part2EgressFilter.call(resource)
      end

      test "labelled resource whose meta.extension is not an Array is refused" do
        resource = condition("meta" => { "security" => [ PART2_LABEL ], "extension" => { "url" => "x" } })

        assert_nil Part2EgressFilter.call(resource)
      end

      test "symbol-keyed labelled resource whose meta.extension is not an Array is refused" do
        resource = { resourceType: "Condition", id: "syn-1", meta: { security: [ { code: "SUD" } ], extension: "x" } }

        assert_nil Part2EgressFilter.call(resource)
      end

      test "Bundle with a labelled entry that cannot carry the notice is refused" do
        bad = condition("meta" => { "security" => [ PART2_LABEL ], "extension" => "not-an-array" })
        bundle = bundle_of(entry(condition, mode: "match"), entry(bad, mode: "include"))

        assert_nil Part2EgressFilter.call(bundle)
      end

      test "Bundle with a labelled resource whose own meta cannot carry the notice is refused" do
        bundle = bundle_of(entry(condition("meta" => { "security" => [ PART2_LABEL ] }), mode: "match"))
          .merge("meta" => { "extension" => "not-an-array" })

        assert_nil Part2EgressFilter.call(bundle)
      end

      test "NDJSON with a labelled line that cannot carry the notice is refused" do
        bad = condition("meta" => { "security" => [ PART2_LABEL ], "extension" => "not-an-array" })
        ndjson = "#{condition.to_json}\n#{bad.to_json}\n"

        assert_nil Part2EgressFilter.call(ndjson)
      end

      test "C-CDA sections with a Part 2-labelled condition row are refused" do
        sections = ccda_sections(
          conditions: [
            { code: "E11.9", display: "Synthetic unlabelled", code_system: nil },
            { code: "F10.20", display: "x", security: [ { code: "42CFRPart2" } ] }
          ]
        )

        assert_nil Part2EgressFilter.call(sections)
      end

      %w[42CFRPart2 ETH SUD].each do |code|
        %i[allergies conditions medications].each do |list|
          test "C-CDA sections with a #{code} label in #{list} are refused" do
            row = { code: "SYN-1", display: "Synthetic", code_system: nil, security: [ { code: code } ] }

            assert_nil Part2EgressFilter.call(ccda_sections(list => [ row ]))
          end
        end
      end

      test "C-CDA sections with a string-keyed security label are refused" do
        row = { code: "SYN-1", display: "Synthetic", "security" => [ { "code" => "SUD" } ] }

        assert_nil Part2EgressFilter.call(ccda_sections(medications: [ row ]))
      end

      test "a Part 2 label under a security key outside meta is refused" do
        # A label the filter has no place to notice: not in meta.security.
        resource = condition("security" => [ { "code" => "42CFRPart2" } ])

        assert_nil Part2EgressFilter.call(resource)
      end

      test "a CSV line that names 42CFRPart2 is refused" do
        csv = "id,event_type,action,detail\n1,rest,R,plain\n2,rest,R,42CFRPart2\n"

        assert_nil Part2EgressFilter.call(csv)
      end

      test "a JSON export String that is not a FHIR resource and names 42CFRPart2 is refused" do
        json = { "export" => "synthetic", "security" => [ { "code" => "42CFRPart2" } ] }.to_json

        assert_nil Part2EgressFilter.call(json)
      end

      test "an NDJSON file with an unparseable line that names 42CFRPart2 is refused" do
        ndjson = "#{condition.to_json}\nnot json 42CFRPart2\n"

        assert_nil Part2EgressFilter.call(ndjson)
      end

      private

      def condition(overrides = {})
        {
          "resourceType" => "Condition", "id" => "syn-1",
          "code" => { "text" => "Synthetic condition" },
          "subject" => { "reference" => "Patient/syn-pt" }
        }.merge(overrides)
      end

      def entry(resource, mode:)
        { "fullUrl" => "https://example.test/#{resource['resourceType']}/#{resource['id']}",
          "resource" => resource, "search" => { "mode" => mode } }
      end

      def bundle_of(*entries)
        { "resourceType" => "Bundle", "type" => "searchset", "total" => entries.size, "entry" => entries }
      end

      def ccda_sections(overrides = {})
        {
          patient: { dfn: "1", name: { family: "SYNTHETIC", given: "PATIENT" }, dob: nil, sex: "F", address: {} },
          allergies: [ { code: "SYN-A", display: "Synthetic allergen", code_system: nil } ],
          conditions: [ { code: "E11.9", display: "Synthetic condition", code_system: nil } ],
          medications: [ { code: "SYN-M", display: "Synthetic medication", code_system: nil } ]
        }.merge(overrides)
      end

      # Noticed: meta.security has the REFRAIN coding and meta.extension has
      # the notice extension. Key style (string or symbol) does not matter.
      def assert_noticed(element, message = nil)
        assert_kind_of Hash, element, "expected a FHIR element, got #{element.inspect[0, 80]}"
        assert refrain_count(element).positive?,
          message || "expected meta.security to carry the NORDSCLCD refrain coding: #{meta_of(element).inspect}"
        assert notice_count(element).positive?,
          message || "expected meta.extension to carry the 2.32 notice: #{meta_of(element).inspect}"
      end

      def refute_noticed(element, message = nil)
        assert_kind_of Hash, element
        assert_equal 0, refrain_count(element), message || "unlabelled element must not carry the refrain coding"
        assert_equal 0, notice_count(element), message || "unlabelled element must not carry the notice extension"
      end

      def meta_of(element)
        meta = element.deep_stringify_keys["meta"]
        meta.is_a?(Hash) ? meta : {}
      end

      def refrain_count(element)
        refrain = Part2RedisclosureNotice::REFRAIN
        Array(meta_of(element)["security"]).count do |coding|
          coding.is_a?(Hash) && coding.slice("system", "code") == refrain
        end
      end

      def notice_count(element)
        notice = {
          "url" => Part2RedisclosureNotice::EXTENSION_URL,
          "valueString" => Part2RedisclosureNotice::TEXT
        }
        Array(meta_of(element)["extension"]).count { |extension| extension == notice }
      end

      # The element as it was before the notice went on: string keys, the
      # REFRAIN coding and the notice extension taken back off.
      def without_notice(element)
        stripped = element.deep_stringify_keys
        meta = stripped["meta"].dup
        refrain = Part2RedisclosureNotice::REFRAIN
        meta["security"] = meta["security"].reject { |coding| coding.slice("system", "code") == refrain }
        meta["extension"] = Array(meta["extension"]).reject { |ext| ext["url"] == Part2RedisclosureNotice::EXTENSION_URL }
        meta.delete("extension") if meta["extension"].empty?
        meta.delete("security") if meta["security"].empty?
        meta.empty? ? stripped.except("meta") : stripped.merge("meta" => meta)
      end
    end
  end
end
