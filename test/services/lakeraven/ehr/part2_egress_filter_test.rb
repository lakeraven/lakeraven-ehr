# frozen_string_literal: true

require "test_helper"
require "csv"

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

      test "notice TEXT is the whole 2.32(a)(1) paragraph, word for word" do
        # The one place the paragraph is written out in the tests. It guards
        # the constant against a dropped or altered clause.
        expected = "This record which has been disclosed to you is protected by Federal confidentiality rules " \
          "(42 CFR part 2). These rules prohibit you from using or disclosing this record, or testimony that " \
          "describes the information contained in this record, in any civil, criminal, administrative, or " \
          "legislative proceedings by any Federal, State, or local authority, against the patient, unless " \
          "authorized by the consent of the patient, except as provided at 42 CFR 2.12(c)(5) or as authorized " \
          "by a court in accordance with 42 CFR 2.64 or 2.65. In addition, the Federal rules prohibit you from " \
          "making any other use or disclosure of this record unless at least one of the following applies: " \
          "(i) Further use or disclosure is expressly permitted by the written consent of the individual whose " \
          "information is being disclosed in this record or as otherwise permitted by 42 CFR part 2. (ii) You " \
          "are a covered entity or business associate and have received the record for treatment, payment, or " \
          "health care operations, or (iii) You have received the record from a covered entity or business " \
          "associate as permitted by 45 CFR part 164, subparts A and E. A general authorization for the release " \
          "of medical or other information is NOT sufficient to meet the required elements of written consent " \
          "to further use or redisclose the record (see 42 CFR 2.31)."

        assert_equal expected, Part2RedisclosureNotice::TEXT
      end

      test "notice constants name the extension, the refrain policy and the Part 2 codes" do
        assert_equal "https://lakeraven.com/fhir/StructureDefinition/part2-redisclosure-notice",
          Part2RedisclosureNotice::EXTENSION_URL
        assert_equal({ "system" => ACT_CODE, "code" => "NORDSCLCD" }, Part2RedisclosureNotice::REFRAIN)
        assert_equal %w[42CFRPart2 ETH SUD ETHUD OPIOIDUD], Part2RedisclosureNotice::PART2_CODES
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

      %w[42CFRPart2 ETH SUD ETHUD OPIOIDUD].each do |code|
        test "a meta.security code of #{code} with no system counts as Part 2" do
          resource = condition("meta" => { "security" => [ { "code" => code } ] })

          result = Part2EgressFilter.call(resource)

          assert_noticed result
          assert_equal resource, without_notice(result)
        end
      end

      # Matching is fail-closed normalised: to_s, strip, compare without case.
      {
        "lower-case 42cfrpart2" => "42cfrpart2",
        "SUD with trailing space" => "SUD ",
        "ETH with surrounding whitespace" => " ETH\t",
        "Symbol :ETH" => :ETH,
        "lower-case ethud" => "ethud",
        "mixed-case OpioidUD" => "OpioidUD"
      }.each do |name, code|
        test "a meta.security code written as #{name} counts as Part 2" do
          resource = condition("meta" => { "security" => [ { "code" => code } ] })

          result = Part2EgressFilter.call(resource)

          assert_noticed result
          assert_equal resource["meta"]["security"], result["meta"]["security"].first(1),
            "the label itself is left as it was written"
        end
      end

      test "a symbol-keyed meta.security code in another case counts as Part 2" do
        resource = { resourceType: "Condition", id: "syn-1", meta: { security: [ { code: "sud" } ] } }

        assert_noticed Part2EgressFilter.call(resource)
      end

      test "a normalised label in a Bundle entry notices the entry and the Bundle" do
        bundle = bundle_of(entry(condition("meta" => { "security" => [ { "code" => "opioidud " } ] }), mode: "match"))

        result = Part2EgressFilter.call(bundle)

        assert_noticed result
        assert_noticed result["entry"][0]["resource"]
      end

      test "a normalised label in a C-CDA row is refused" do
        row = { code: "SYN-1", display: "Synthetic", code_system: nil, security: [ { code: "42cfrpart2" } ] }

        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
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

      test "a resource that contains a labelled resource is itself noticed" do
        # FHIR dom-5: a contained resource may not carry a security label,
        # so the notice has to be on the container that leaves.
        contained = { "resourceType" => "Observation", "id" => "syn-contained", "meta" => { "security" => [ PART2_LABEL ] } }
        resource = condition("contained" => [ contained, { "resourceType" => "Practitioner", "id" => "syn-pr" } ])

        result = Part2EgressFilter.call(resource)

        assert_noticed result, "the container of a labelled resource must carry the notice"
        assert_equal 1, refrain_count(result)
        assert_equal 1, notice_count(result)
        assert_equal resource.except("contained"), without_notice(result).except("contained")
      end

      test "a container that already has meta keeps it and is noticed" do
        contained = { "resourceType" => "Observation", "id" => "syn-contained", "meta" => { "security" => [ { "code" => "SUD" } ] } }
        resource = condition("meta" => { "versionId" => "2", "security" => [ UNRELATED_LABEL ] }, "contained" => [ contained ])

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_equal resource["meta"], without_notice(result)["meta"]
      end

      test "a symbol-keyed container of a labelled resource is noticed" do
        resource = {
          resourceType: "Condition", id: "syn-1",
          contained: [ { resourceType: "Observation", id: "syn-contained", meta: { security: [ { code: "ETH" } ] } } ]
        }

        assert_noticed Part2EgressFilter.call(resource)
      end

      test "a container with only unlabelled contained resources is not noticed" do
        resource = condition("contained" => [ { "resourceType" => "Practitioner", "id" => "syn-pr" } ])

        result = Part2EgressFilter.call(resource)

        assert_equal resource, result
        refute_noticed result
      end

      test "a Bundle entry that contains a labelled resource is itself noticed" do
        contained = { "resourceType" => "Observation", "id" => "syn-contained", "meta" => { "security" => [ PART2_LABEL ] } }
        bundle = bundle_of(entry(condition("contained" => [ contained ]), mode: "match"), entry(condition("id" => "syn-2"), mode: "match"))

        result = Part2EgressFilter.call(bundle)

        assert_noticed result
        assert_noticed result["entry"][0]["resource"]
        refute_noticed result["entry"][1]["resource"]
      end

      test "a Parameters resource whose parameter resource is labelled is noticed" do
        labelled = condition("meta" => { "security" => [ PART2_LABEL ] })
        parameters = {
          "resourceType" => "Parameters", "id" => "syn-params",
          "parameter" => [
            { "name" => "synthetic-flag", "valueBoolean" => true },
            { "name" => "synthetic-resource", "resource" => labelled }
          ]
        }

        result = Part2EgressFilter.call(parameters)

        assert_noticed result, "a Parameters that carries a labelled resource must carry the notice"
        assert_noticed result["parameter"][1]["resource"]
        assert_equal labelled, without_notice(result["parameter"][1]["resource"])
        assert_equal parameters["parameter"][0], result["parameter"][0]
      end

      test "a Parameters resource with no labelled resource is not noticed" do
        parameters = {
          "resourceType" => "Parameters", "id" => "syn-params",
          "parameter" => [ { "name" => "synthetic-resource", "resource" => condition } ]
        }

        result = Part2EgressFilter.call(parameters)

        assert_equal parameters, result
        refute_noticed result
      end

      test "an NDJSON line whose resource contains a labelled resource is noticed" do
        contained = { "resourceType" => "Observation", "id" => "syn-contained", "meta" => { "security" => [ { "code" => "SUD" } ] } }
        ndjson = "#{condition('contained' => [ contained ]).to_json}\n"

        result = Part2EgressFilter.call(ndjson)

        assert_noticed JSON.parse(result.lines.first)
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

      test "a stale notice extension is replaced by the current notice" do
        stale = { "url" => Part2RedisclosureNotice::EXTENSION_URL, "valueString" => "Synthetic out-of-date notice" }
        other = { "url" => "https://example.test/fhir/StructureDefinition/synthetic", "valueString" => "x" }
        resource = condition("meta" => { "security" => [ PART2_LABEL ], "extension" => [ other, stale ] })

        result = Part2EgressFilter.call(resource)
        with_url = result["meta"]["extension"].select { |ext| ext["url"] == Part2RedisclosureNotice::EXTENSION_URL }

        assert_equal 1, with_url.size, "exactly one extension entry for the notice URL"
        assert_equal Part2RedisclosureNotice::TEXT, with_url.first["valueString"]
        assert_noticed result
        assert_includes result["meta"]["extension"], other
        assert_equal stale, resource["meta"]["extension"][1], "the input keeps its stale entry"
      end

      test "a symbol-keyed stale notice extension is replaced by the current notice" do
        resource = {
          resourceType: "Condition", id: "syn-1",
          meta: {
            security: [ { code: "42CFRPart2" } ],
            extension: [ { url: Part2RedisclosureNotice::EXTENSION_URL, valueString: "Synthetic out-of-date notice" } ]
          }
        }

        result = Part2EgressFilter.call(resource).deep_stringify_keys
        with_url = result["meta"]["extension"].select { |ext| ext["url"] == Part2RedisclosureNotice::EXTENSION_URL }

        assert_equal 1, with_url.size
        assert_equal Part2RedisclosureNotice::TEXT, with_url.first["valueString"]
      end

      test "several stale notice entries collapse to the one current notice" do
        stale = ->(text) { { "url" => Part2RedisclosureNotice::EXTENSION_URL, "valueString" => text } }
        resource = condition(
          "meta" => { "security" => [ PART2_LABEL ], "extension" => [ stale.("Synthetic old A"), stale.("Synthetic old B") ] }
        )

        result = Part2EgressFilter.call(resource)
        with_url = result["meta"]["extension"].select { |ext| ext["url"] == Part2RedisclosureNotice::EXTENSION_URL }

        assert_equal [ Part2RedisclosureNotice::TEXT ], with_url.map { |ext| ext["valueString"] }
        assert_equal result, Part2EgressFilter.call(result)
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

      %w[42CFRPart2 ETH SUD ETHUD OPIOIDUD].each do |code|
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

      # --- a label inside meta that is malformed or misplaced refuses -------

      MISPLACED_META = {
        "a CodeableConcept in meta.security" => { "security" => [ { "coding" => [ { "code" => "SUD" } ] } ] },
        "a nested Array in meta.security" => { "security" => [ [ { "code" => "SUD" } ] ] },
        "a Part 2 code in meta.tag" => { "tag" => [ { "code" => "42CFRPart2" } ] },
        "a Part 2 valueCoding in meta.extension" => { "extension" => [ { "url" => "x", "valueCoding" => { "code" => "ETH" } } ] },
        "a normalised Part 2 code in meta.tag" => { "tag" => [ { "code" => "opioidud " } ] },
        "a misplaced code beside a proper label" => { "security" => [ { "code" => "42CFRPart2" } ], "tag" => [ { "code" => "ETHUD" } ] }
      }.freeze

      MISPLACED_META.each do |name, meta|
        test "#{name} is refused" do
          assert_nil Part2EgressFilter.call(condition("meta" => meta))
        end

        test "#{name} is refused in a Bundle entry" do
          bundle = bundle_of(entry(condition, mode: "match"), entry(condition("id" => "syn-2", "meta" => meta), mode: "include"))

          assert_nil Part2EgressFilter.call(bundle)
        end

        test "#{name} is refused on an NDJSON line" do
          ndjson = "#{condition.to_json}\n#{condition('meta' => meta).to_json}\n"

          assert_nil Part2EgressFilter.call(ndjson)
        end
      end

      test "a symbol-keyed Part 2 code in meta.tag is refused" do
        resource = { resourceType: "Condition", id: "syn-1", meta: { tag: [ { code: "SUD" } ] } }

        assert_nil Part2EgressFilter.call(resource)
      end

      test "the notice extension already in meta is not a misplaced label" do
        once = Part2EgressFilter.call(condition("meta" => { "security" => [ PART2_LABEL ] }))

        assert_equal once, Part2EgressFilter.call(once)
      end

      test "meta.tag and meta.extension with no Part 2 code are left alone" do
        resource = condition(
          "meta" => {
            "tag" => [ { "code" => "syn" } ],
            "extension" => [ { "url" => "x", "valueCoding" => { "code" => "N" } } ],
            "security" => [ UNRELATED_LABEL ]
          }
        )

        assert_equal resource, Part2EgressFilter.call(resource)
      end

      # --- a String that is one JSON document over several lines ------------

      test "an unlabelled pretty-printed JSON document is returned byte-identical" do
        text = JSON.pretty_generate(export_manifest)

        result = Part2EgressFilter.call(text)

        assert_operator text.lines.size, :>, 1
        assert_equal text, result
        assert_equal text.bytes, result.bytes
      end

      test "an unlabelled pretty-printed JSON document with a trailing newline is returned byte-identical" do
        text = "#{JSON.pretty_generate(export_manifest('security' => [ UNRELATED_LABEL ]))}\n"

        assert_equal text.bytes, Part2EgressFilter.call(text).bytes
      end

      %w[ETH SUD ETHUD OPIOIDUD 42CFRPart2].each do |code|
        test "a pretty-printed JSON document with a #{code} security label is refused" do
          text = JSON.pretty_generate(export_manifest("security" => [ { "system" => ACT_CODE, "code" => code } ]))

          assert_nil Part2EgressFilter.call(text)
        end
      end

      test "a pretty-printed JSON document that holds an ETH-labelled resource is refused" do
        labelled = condition("meta" => { "security" => [ { "code" => "ETH" } ] })
        text = JSON.pretty_generate(export_manifest("output" => [ { "type" => "Condition", "resource" => labelled } ]))

        assert_nil Part2EgressFilter.call(text)
      end

      test "a pretty-printed JSON document that holds a SUD-labelled resource deep inside is refused" do
        labelled = { "resourceType" => "Observation", "id" => "syn-obs", "meta" => { "security" => [ { "code" => "SUD" } ] } }
        text = JSON.pretty_generate(export_manifest("extension" => { "items" => [ { "detail" => [ labelled ] } ] }))

        assert_nil Part2EgressFilter.call(text)
      end

      test "a pretty-printed JSON document with a normalised label is refused" do
        text = JSON.pretty_generate(export_manifest("security" => [ { "code" => "sud " } ]))

        assert_nil Part2EgressFilter.call(text)
      end

      test "a pretty-printed JSON document with a Part 2 code in a resource's meta.tag is refused" do
        misplaced = condition("meta" => { "tag" => [ { "code" => "SUD" } ] })
        text = JSON.pretty_generate(export_manifest("output" => [ { "resource" => misplaced } ]))

        assert_nil Part2EgressFilter.call(text)
      end

      # --- lines that are not JSON -------------------------------------------

      %w[ETH SUD ETHUD OPIOIDUD].each do |code|
        test "a CSV row with #{code} as a word inside a longer field is unchanged" do
          # Round 3, a deliberate narrowing: this test used to expect a refusal.
          # A short code that is only a word inside a longer CSV field no
          # longer refuses. The audit CSV Description is free text (recipient
          # names, access reasons), so the word match refused the whole
          # 45 CFR 170.315(b)(10) audit export with a permanent 503 for exactly
          # the Part 2 population. The audit log is not a carrier of security
          # labels. A short code that IS a whole field still refuses, and
          # 42CFRPart2 itself still refuses anywhere in the line.
          csv = "id,event_type,action,detail\n1,rest,R,plain\n2,rest,R,label #{code} applied\n"

          result = Part2EgressFilter.call(csv)

          assert_equal csv, result
          assert_equal csv.bytes, result.bytes
        end

        test "a CSV row with #{code} as a whole field is refused" do
          csv = "id,event_type,action,detail\n2,rest,R,#{code}\n"

          assert_nil Part2EgressFilter.call(csv)
        end
      end

      test "a CSV row that names 42CFRPart2 in another case is refused" do
        [ "42cfrpart2", "42CFRPART2", "x42CfrPart2y" ].each do |spelling|
          csv = "id,event_type,action,detail\n2,rest,R,#{spelling}\n"

          assert_nil Part2EgressFilter.call(csv), "#{spelling} in a CSV row must refuse"
        end
      end

      # Round 2, a deliberate strengthening: this test used to expect the
      # lower-case words `eth`, `sud`, `ethud` and `opioidud` to pass
      # unchanged. The short codes now match without regard to case, so those
      # rows refuse (see "short codes in text match without regard to case"
      # below). What stays unchanged is a word that only CONTAINS the letters.
      test "a CSV row whose words only contain the letters of a short code is unchanged" do
        csv = "id,event_type,action,detail\n" \
          "1,rest,R,METHOD PSEUDO Sudden\n" \
          "2,rest,R,method pseudo sudden ethanol suds\n" \
          "3,rest,R,ETHANOL SUDS METHADONE_SUDX XETH\n"

        result = Part2EgressFilter.call(csv)

        assert_equal csv, result
        assert_equal csv.bytes, result.bytes
      end

      test "a byte order mark does not hide a labelled NDJSON line" do
        [ { "code" => "SUD" }, { "code" => "ETH" }, PART2_LABEL ].each do |label|
          labelled = condition("meta" => { "security" => [ label ] })
          ndjson = "\uFEFF#{labelled.to_json}\n"

          result = Part2EgressFilter.call(ndjson)

          refute_equal ndjson, result, "a BOM-prefixed labelled line (#{label['code']}) must not leave unchanged"
          next if result.nil?

          assert_noticed JSON.parse(result.lines.first.delete_prefix("\uFEFF"))
        end
      end

      test "a byte order mark before a later labelled line does not hide it" do
        labelled = condition("meta" => { "security" => [ { "code" => "SUD" } ] })
        ndjson = "#{condition.to_json}\n\uFEFF#{labelled.to_json}\n"

        result = Part2EgressFilter.call(ndjson)

        refute_equal ndjson, result
        assert_noticed JSON.parse(result.lines[1].delete_prefix("\uFEFF")) unless result.nil?
      end

      test "a String with invalid UTF-8 bytes is refused and does not raise" do
        [
          "id,event_type\n1,\xFF\xFE\n",
          "#{condition.to_json}\n\xC3\x28\n",
          "\xFF"
        ].each do |text|
          bad = text.dup.force_encoding(Encoding::UTF_8)
          refute bad.valid_encoding?, "test data must be invalid UTF-8"

          result = nil
          assert_nothing_raised { result = Part2EgressFilter.call(bad) }
          assert_nil result, "invalid UTF-8 cannot be examined, so it must not leave"
        end
      end

      # === round 2 ==========================================================

      # --- a sections-shaped Hash cannot carry the notice --------------------

      # The C-CDA is built from a Hash that is not a FHIR resource. The
      # notice has nowhere to go in that document, so a resource inside the
      # Hash that the FHIR path would notice (or refuse) refuses the whole.
      LABELLED_FOR_SECTIONS = {
        "a 42CFRPart2 label" => { "meta" => { "security" => [ PART2_LABEL ] } },
        "a SUD label" => { "meta" => { "security" => [ { "code" => "SUD" } ] } },
        "a label on a contained resource" => {
          "contained" => [ { "resourceType" => "Observation", "id" => "syn-c", "meta" => { "security" => [ { "code" => "ETH" } ] } } ]
        }
      }.freeze

      LABELLED_FOR_SECTIONS.each do |name, overrides|
        test "C-CDA sections whose condition row holds a resource with #{name} are refused" do
          row = { code: "SYN-1", display: "Synthetic", code_system: nil, fhir: condition(overrides) }

          assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
        end

        test "C-CDA sections whose patient holds a resource with #{name} are refused" do
          patient = ccda_sections[:patient].merge(fhir: condition(overrides).merge("resourceType" => "Patient"))

          assert_nil Part2EgressFilter.call(ccda_sections(patient: patient))
        end

        test "a non-resource Hash holding a resource with #{name} under any key is refused" do
          [ :fhir, "source", :anything_at_all ].each do |key|
            assert_nil Part2EgressFilter.call({ key => condition(overrides) }), "under #{key.inspect}"
            assert_nil Part2EgressFilter.call({ rows: [ { nested: { key => condition(overrides) } } ] }), "deep under #{key.inspect}"
          end
        end
      end

      test "C-CDA sections holding a symbol-keyed labelled resource are refused" do
        resource = { resourceType: "AllergyIntolerance", id: "syn-1", meta: { security: [ { code: "42CFRPart2" } ] } }
        row = { code: "SYN-A", display: "Synthetic allergen", code_system: nil, fhir: resource }

        assert_nil Part2EgressFilter.call(ccda_sections(allergies: [ row ]))
      end

      test "C-CDA sections holding a resource the FHIR path would refuse are refused" do
        row = { code: "SYN-M", display: "Synthetic medication", code_system: nil,
                fhir: condition("meta" => { "tag" => [ { "code" => "SUD" } ] }) }

        assert_nil Part2EgressFilter.call(ccda_sections(medications: [ row ]))
      end

      test "C-CDA sections holding only unlabelled resources are returned equal" do
        patient = ccda_sections[:patient].merge(fhir: { "resourceType" => "Patient", "id" => "syn-pt" })
        sections = ccda_sections(
          patient: patient,
          conditions: [
            { code: "E11.9", display: "Synthetic condition", code_system: nil,
              fhir: condition("meta" => { "security" => [ UNRELATED_LABEL ] }) },
            { code: "SYN-2", display: "Synthetic two", code_system: nil,
              fhir: condition("contained" => [ { "resourceType" => "Observation", "id" => "syn-c" } ]) }
          ]
        )
        before = sections.deep_dup

        result = Part2EgressFilter.call(sections)

        assert_equal before, result
        assert_equal before, sections, "the input must not be mutated"
      end

      test "a labelled resource at the top level is still noticed, not refused" do
        # The refusal is for a Hash that is not a resource. A resource, and
        # a Bundle of them, carry the notice themselves.
        assert_noticed Part2EgressFilter.call(condition("meta" => { "security" => [ PART2_LABEL ] }))
        bundle = bundle_of(entry(condition("meta" => { "security" => [ PART2_LABEL ] }), mode: "match"))
        assert_noticed Part2EgressFilter.call(bundle)
      end

      # --- short codes in text match without regard to case ------------------

      %w[sud eth ethud opioidud Sud Eth EthUD OpioidUD].each do |code|
        test "a CSV row with #{code} as a whole field in another case is refused" do
          assert_nil Part2EgressFilter.call("id,detail\nx,#{code}\n")
        end

        test "a CSV row with #{code} as a word inside a longer field in another case is unchanged" do
          # Round 3, a deliberate narrowing: this test used to expect a refusal.
          # A short code that is only a word inside a longer CSV field no
          # longer refuses. The audit CSV Description is free text (recipient
          # names, access reasons), so the word match refused the whole
          # 45 CFR 170.315(b)(10) audit export with a permanent 503 for exactly
          # the Part 2 population. The audit log is not a carrier of security
          # labels. A short code that IS a whole field still refuses, and
          # 42CFRPart2 itself still refuses anywhere in the line.
          csv = "id,event_type,action,detail\n2,rest,R,label #{code} applied\n"

          assert_equal csv, Part2EgressFilter.call(csv)
        end
      end

      test "a text line that is not JSON and names a short code as a word in prose is unchanged" do
        # Round 3, a deliberate narrowing: this test used to expect a refusal.
        # A short code that is only a word inside a longer CSV field no
        # longer refuses. The audit CSV Description is free text (recipient
        # names, access reasons), so the word match refused the whole
        # 45 CFR 170.315(b)(10) audit export with a permanent 503 for exactly
        # the Part 2 population. The audit log is not a carrier of security
        # labels. A short code that IS a whole field still refuses, and
        # 42CFRPart2 itself still refuses anywhere in the line.
        text = "#{condition.to_json}\nnot json sud\n"

        assert_equal text, Part2EgressFilter.call(text)
        assert_nil Part2EgressFilter.call("#{condition.to_json}\nnot json,sud\n"), "a whole field still refuses"
      end

      # --- DocumentReference.securityLabel -----------------------------------

      test "a Part 2 code in securityLabel labels the resource and it is noticed" do
        [ "42CFRPart2", "ETH", "SUD", "ETHUD", "OPIOIDUD", "sud " ].each do |code|
          resource = document_reference("securityLabel" => [ { "coding" => [ { "system" => ACT_CODE, "code" => code } ] } ])
          before = resource.deep_dup

          result = Part2EgressFilter.call(resource)

          assert_noticed result, "securityLabel #{code.inspect} must bring the notice"
          assert_equal before.except("meta"), result.except("meta"), "every other element is unchanged"
          assert_equal before, resource, "the input must not be mutated"
        end
      end

      test "a Part 2 code in a later coding of a later securityLabel is noticed" do
        resource = document_reference(
          "securityLabel" => [
            { "coding" => [ UNRELATED_LABEL ] },
            { "coding" => [ UNRELATED_LABEL, { "code" => "SUD" } ], "text" => "Synthetic" }
          ]
        )

        assert_noticed Part2EgressFilter.call(resource)
      end

      test "a symbol-keyed securityLabel with a Part 2 code is noticed" do
        resource = { resourceType: "DocumentReference", id: "syn-doc", status: "current",
                     securityLabel: [ { coding: [ { code: "42CFRPart2" } ] } ] }

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_equal resource.except(:meta), result.except(:meta)
      end

      test "a securityLabel-labelled resource keeps its meta and gets one notice" do
        resource = document_reference(
          "meta" => { "versionId" => "3", "security" => [ UNRELATED_LABEL ] },
          "securityLabel" => [ { "coding" => [ { "code" => "ETH" } ] } ]
        )

        result = Part2EgressFilter.call(resource)

        assert_noticed result
        assert_equal "3", result["meta"]["versionId"]
        assert_includes result["meta"]["security"], UNRELATED_LABEL
        assert_equal 1, notice_count(result)
        assert_equal result, Part2EgressFilter.call(result), "idempotent"
      end

      test "a securityLabel with no Part 2 code is returned equal and not noticed" do
        resource = document_reference("securityLabel" => [ { "coding" => [ UNRELATED_LABEL ], "text" => "Synthetic" } ])

        result = Part2EgressFilter.call(resource)

        assert_equal resource, result
        refute_noticed result
      end

      MALFORMED_SECURITY_LABEL = {
        "a single CodeableConcept" => { "coding" => [ { "code" => "SUD" } ] },
        "a single Coding" => { "code" => "42CFRPart2" },
        "a bare String" => "ETH"
      }.freeze

      MALFORMED_SECURITY_LABEL.each do |name, value|
        test "a securityLabel that is #{name}, not an Array, holding a Part 2 code is refused" do
          assert_nil Part2EgressFilter.call(document_reference("securityLabel" => value))
        end
      end

      test "a symbol-keyed securityLabel that is not an Array and holds a Part 2 code is refused" do
        resource = { resourceType: "DocumentReference", id: "syn-doc", securityLabel: { coding: [ { code: "SUD" } ] } }

        assert_nil Part2EgressFilter.call(resource)
      end

      test "a Part 2 securityLabel on a Bundle entry notices the entry and the Bundle" do
        labelled = document_reference("securityLabel" => [ { "coding" => [ { "code" => "SUD" } ] } ])
        bundle = bundle_of(entry(condition, mode: "match"), entry(labelled, mode: "include"))

        result = Part2EgressFilter.call(bundle)

        assert_noticed result, "the Bundle carries the notice for the entry"
        assert_noticed result["entry"][1]["resource"]
        refute_noticed result["entry"][0]["resource"]
      end

      test "a Part 2 securityLabel on an NDJSON line is noticed" do
        labelled = document_reference("securityLabel" => [ { "coding" => [ { "code" => "42CFRPart2" } ] } ])
        ndjson = "#{condition.to_json}\n#{labelled.to_json}\n"

        result = Part2EgressFilter.call(ndjson)

        assert_kind_of String, result
        assert_equal condition.to_json, result.lines[0].chomp
        assert_noticed JSON.parse(result.lines[1])
      end

      test "C-CDA sections holding a securityLabel-labelled resource are refused" do
        row = { code: "SYN-1", display: "Synthetic", code_system: nil,
                fhir: document_reference("securityLabel" => [ { "coding" => [ { "code" => "SUD" } ] } ]) }

        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
      end

      # --- the shape of a meta.security Coding -------------------------------

      NON_SCALAR_CODES = {
        "a Hash" => { "value" => "SUD" },
        "a symbol-keyed Hash" => { value: "42CFRPart2" },
        "an Array" => [ "ETH" ],
        "a nested Array" => [ [ "OPIOIDUD" ] ],
        "an Array of Hashes" => [ { "code" => "sud " } ]
      }.freeze

      NON_SCALAR_CODES.each do |name, code|
        test "a meta.security code that is #{name} holding a Part 2 value is refused" do
          assert_nil Part2EgressFilter.call(condition("meta" => { "security" => [ { "system" => ACT_CODE, "code" => code } ] }))
        end

        test "a symbol-keyed meta.security code that is #{name} holding a Part 2 value is refused" do
          resource = { resourceType: "Condition", id: "syn-1", meta: { security: [ { code: code } ] } }

          assert_nil Part2EgressFilter.call(resource)
        end
      end

      test "a meta.security code that is a Hash or Array with no Part 2 value is left alone" do
        resource = condition("meta" => { "security" => [ { "code" => { "value" => "N" } }, { "code" => [ "R" ] } ] })

        assert_equal resource, Part2EgressFilter.call(resource)
      end

      test "a Coding with both code keys is labelled when either is a Part 2 code" do
        [
          { "code" => "N", :code => "SUD" },
          { "code" => "SUD", :code => "N" },
          { :code => "42CFRPart2", "code" => "R" },
          { "code" => nil, :code => "ETH" },
          { "code" => "", :code => "ethud" }
        ].each do |coding|
          resource = condition("meta" => { "security" => [ coding ] })

          result = Part2EgressFilter.call(resource)

          assert_noticed result, "#{coding.inspect} must count as a Part 2 label"
          assert_includes result["meta"]["security"], coding, "the original coding is kept"
        end
      end

      UNICODE_PADDING = {
        "U+00A0 no-break space" => " ",
        "U+200B zero width space" => "​",
        "U+FEFF zero width no-break space" => "﻿",
        "U+2003 em space" => " ",
        "U+3000 ideographic space" => "　"
      }.freeze

      UNICODE_PADDING.each do |name, pad|
        test "a meta.security code padded with #{name} counts as Part 2" do
          [ "#{pad}SUD", "SUD#{pad}", "#{pad}42CFRPart2#{pad}", " #{pad} eth #{pad} " ].each do |code|
            result = Part2EgressFilter.call(condition("meta" => { "security" => [ { "code" => code } ] }))

            assert_noticed result, "#{code.inspect} must count as a Part 2 label"
          end
        end

        test "a Bundle entry code padded with #{name} notices the entry and the Bundle" do
          labelled = condition("id" => "syn-2", "meta" => { "security" => [ { "code" => "ETHUD#{pad}" } ] })

          result = Part2EgressFilter.call(bundle_of(entry(condition, mode: "match"), entry(labelled, mode: "match")))

          assert_noticed result
          assert_noticed result["entry"][1]["resource"]
        end

        test "a C-CDA row code padded with #{name} is refused" do
          row = { code: "SYN-1", display: "Synthetic", code_system: nil, security: [ { code: "#{pad}SUD#{pad}" } ] }

          assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
        end
      end

      test "a code that only contains a Part 2 code inside other letters is not a label" do
        resource = condition("meta" => { "security" => [ { "code" => "X​SUD" }, { "code" => "SUDS" } ] })

        assert_equal resource, Part2EgressFilter.call(resource)
      end

      # --- display is text, not a label ---------------------------------------

      test "a Coding whose display echoes its Part 2 code is noticed, not refused" do
        %w[ETH SUD 42CFRPart2 ETHUD OPIOIDUD].each do |code|
          coding = { "system" => ACT_CODE, "code" => code, "display" => code }
          resource = condition("meta" => { "security" => [ coding ] })

          result = Part2EgressFilter.call(resource)

          assert_noticed result, "display #{code} beside code #{code} is the same label, not a misplaced one"
          assert_includes result["meta"]["security"], coding
        end
      end

      test "a symbol-keyed Coding whose display echoes its Part 2 code is noticed" do
        resource = { resourceType: "Condition", id: "syn-1", meta: { security: [ { code: "ETH", display: "ETH" } ] } }

        assert_noticed Part2EgressFilter.call(resource)
      end

      test "a Bundle entry and an NDJSON line whose display echoes the code are noticed" do
        labelled = condition("id" => "syn-2", "meta" => { "security" => [ { "code" => "SUD", "display" => "SUD" } ] })

        bundle = Part2EgressFilter.call(bundle_of(entry(labelled, mode: "match")))
        assert_noticed bundle
        assert_noticed bundle["entry"][0]["resource"]

        ndjson = Part2EgressFilter.call("#{labelled.to_json}\n")
        assert_kind_of String, ndjson
        assert_noticed JSON.parse(ndjson)
      end

      test "a display that names a Part 2 code beside another code is not a label and not refused" do
        # No existing test asserted otherwise. display is human text.
        [ { "code" => "N", "display" => "SUD" }, { code: "N", display: "ETH" },
          { "system" => ACT_CODE, "code" => "R", "display" => "42CFRPart2" } ].each do |coding|
          resource = condition("meta" => { "security" => [ coding ] })

          result = Part2EgressFilter.call(resource)

          assert_equal resource, result, "#{coding.inspect} must leave the resource as it was"
          refute_noticed result
        end
      end

      # --- one labelled NDJSON line with blank lines around it ----------------

      test "a single labelled NDJSON line followed by a blank line is noticed" do
        labelled = condition("meta" => { "security" => [ PART2_LABEL ] })
        noticed = Part2EgressFilter.call(labelled)

        result = Part2EgressFilter.call("#{labelled.to_json}\n\n")

        assert_equal "#{noticed.to_json}\n\n", result
      end

      test "a single labelled NDJSON line after a blank line is noticed" do
        labelled = condition("meta" => { "security" => [ { "code" => "SUD" } ] })
        noticed = Part2EgressFilter.call(labelled)

        result = Part2EgressFilter.call("\n#{labelled.to_json}\n")

        assert_equal "\n#{noticed.to_json}\n", result
      end

      test "a single labelled NDJSON line between several blank lines is noticed" do
        labelled = condition("meta" => { "security" => [ PART2_LABEL ] })
        noticed = Part2EgressFilter.call(labelled)

        assert_equal "\n\n#{noticed.to_json}\n\n\n", Part2EgressFilter.call("\n\n#{labelled.to_json}\n\n\n")
        assert_equal "#{noticed.to_json}\n\n\n", Part2EgressFilter.call("#{labelled.to_json}\n\n\n")
      end

      test "a single unlabelled NDJSON line with blank lines is returned byte-identical" do
        [ "#{condition.to_json}\n\n", "\n#{condition.to_json}\n" ].each do |ndjson|
          result = Part2EgressFilter.call(ndjson)

          assert_equal ndjson.bytes, result.bytes
        end
      end

      test "a single labelled NDJSON line with blank lines that cannot carry the notice is refused" do
        labelled = condition("meta" => { "security" => [ PART2_LABEL ], "extension" => "not an array" })

        assert_nil Part2EgressFilter.call("#{labelled.to_json}\n\n")
        assert_nil Part2EgressFilter.call("\n#{labelled.to_json}\n")
      end

      # --- round 3: a short code is a whole CSV field, not a word in prose ----
      #
      # A line that is not a FHIR resource refuses when it holds 42CFRPart2
      # anywhere (any case), or when one of its CSV fields, with surrounding
      # quotes and Unicode whitespace taken off, IS one of ETH, SUD, ETHUD,
      # OPIOIDUD (any case). The line is read with Ruby's CSV; a line CSV
      # cannot read is split on commas.

      AUDIT_PROSE = [
        "PHI disclosed to County SUD Clinic for treatment",
        "Emergency access (break-glass): SUD crisis",
        "consent scope sud-counseling signed"
      ].freeze

      test "a realistic audit CSV whose Description names SUD in prose is returned byte-identical" do
        csv = audit_csv(AUDIT_PROSE)

        result = Part2EgressFilter.call(csv)

        assert_equal csv, result, "free text in the audit Description must not refuse the audit export"
        assert_equal csv.bytes, result.bytes
      end

      AUDIT_PROSE.each do |description|
        test "an audit CSV row described as #{description.inspect} is returned byte-identical" do
          csv = audit_csv([ description ])

          assert_equal csv, Part2EgressFilter.call(csv)
        end
      end

      test "an audit CSV whose quoted Description holds a comma and a short code in prose is unchanged" do
        csv = audit_csv([ "Disclosed to Synthetic Clinic, ETH and SUD programme, for treatment" ])
        assert_includes csv, '"Disclosed to Synthetic Clinic, ETH and SUD programme, for treatment"'

        assert_equal csv, Part2EgressFilter.call(csv)
      end

      test "an audit CSV whose Description is a short code and nothing else is refused" do
        %w[SUD eth Ethud OPIOIDUD].each do |code|
          assert_nil Part2EgressFilter.call(audit_csv([ "plain", code ])), "a Description that is #{code} must refuse"
        end
      end

      test "an audit CSV whose Description names 42CFRPart2 in prose is refused" do
        [ "Record labelled 42CFRPart2 disclosed", "label 42cfrpart2", "x42CfrPart2y" ].each do |description|
          assert_nil Part2EgressFilter.call(audit_csv([ description ])), "#{description.inspect} must refuse"
        end
      end

      {
        "x,sud" => "a lower-case whole field",
        '1,"ETH"' => "a quoted whole field",
        "a,SUD" => "a whole field",
        "a, SUD ,b" => "a field padded with spaces",
        'a," SUD "' => "a quoted field padded with spaces",
        "a, sud​,b" => "a field padded with Unicode whitespace",
        "SUD,a" => "a first field",
        "ETHUD" => "a line that is one field",
        '"OpioidUD",1' => "a quoted first field in mixed case",
        'a,"SUD' => "a field of a line CSV cannot read (unclosed quote)",
        'x "y" z,eth' => "a field of a line CSV cannot read (stray quotes)"
      }.each do |line, what|
        test "a short code that is #{what} is refused" do
          assert_nil Part2EgressFilter.call("id,detail\n#{line}\n"), "#{line.inspect} must refuse"
          assert_nil Part2EgressFilter.call("#{condition.to_json}\n#{line}\n"), "#{line.inspect} beside an NDJSON line must refuse"
        end
      end

      # --- round 3: a JSON line that is not a resource gets the text rule -----

      test "a JSON string line that is a Part 2 code is refused" do
        assert_nil Part2EgressFilter.call("a,b\n\"SUD\"\n")
        assert_nil Part2EgressFilter.call("a,b\n\" eth \"\n")
      end

      test "a JSON object line that is not a resource and has a Part 2 code under code is refused" do
        assert_nil Part2EgressFilter.call("{\"code\":\"SUD\"}\n{\"resourceType\":\"Patient\"}\n")
        assert_nil Part2EgressFilter.call("{\"a\":{\"code\":\"ethud\"}}\n{\"resourceType\":\"Patient\"}\n")
        assert_nil Part2EgressFilter.call("{\"code\":[\"N\",\"OPIOIDUD\"]}\n{\"resourceType\":\"Patient\"}\n")
      end

      test "a JSON line that is not a resource and has a Part 2 code as a String leaf is refused" do
        assert_nil Part2EgressFilter.call("[\"N\",\"SUD\"]\n{\"resourceType\":\"Patient\"}\n")
        assert_nil Part2EgressFilter.call("{\"label\":\"ETH\"}\n{\"resourceType\":\"Patient\"}\n")
        assert_nil Part2EgressFilter.call("{\"a\":[{\"b\":\"sud \"}]}\n")
      end

      test "a JSON line that is not a resource and names 42CFRPart2 is refused" do
        assert_nil Part2EgressFilter.call("{\"x\":\"42CFRPart2\"}")
        assert_nil Part2EgressFilter.call("{\"x\":\"42CFRPart2\"}\n{\"resourceType\":\"Patient\"}\n")
        assert_nil Part2EgressFilter.call("{\"x\":\"label 42cfrpart2 applied\"}\n")
      end

      test "a JSON line that is not a resource and holds no Part 2 code is unchanged" do
        text = "{\"note\":\"County SUD Clinic\",\"code\":\"N\",\"n\":1}\n\"plain\"\n[1,\"METHOD\"]\n{\"resourceType\":\"Patient\"}\n"

        assert_equal text, Part2EgressFilter.call(text)
      end

      # --- round 3: a line that looks like JSON and does not parse refuses ----

      {
        "nested deeper than the parser reads" => ("[" * 150) + ("]" * 150),
        "an object nested deeper than the parser reads" => ('{"a":' * 150) + "1" + ("}" * 150),
        "holding NaN" => '{"resourceType":"Observation","id":"syn-o","valueQuantity":{"value":NaN}}',
        "ending in a trailing comma" => '{"resourceType":"Condition","id":"syn-1",}',
        "an array ending in a trailing comma" => "[1,2,]",
        "cut short" => '{"resourceType":"Condition","id":"syn-1"'
      }.each do |what, line|
        test "a line that opens like JSON and does not parse (#{what}) is refused" do
          assert_raises(JSON::ParserError, "test data must not parse") { JSON.parse(line) }

          assert_nil Part2EgressFilter.call(line)
          assert_nil Part2EgressFilter.call("#{line}\n")
          assert_nil Part2EgressFilter.call("#{condition.to_json}\n#{line}\n")
          assert_nil Part2EgressFilter.call("﻿#{line}\n"), "after a byte order mark"
          assert_nil Part2EgressFilter.call("#{condition.to_json}\n  \t#{line}\n"), "after leading whitespace"
        end
      end

      test "a labelled line that opens like JSON and does not parse is refused" do
        deep = ("[" * 150) + { "resourceType" => "Condition", "meta" => { "security" => [ { "code" => "SUD" } ] } }.to_json + ("]" * 150)
        nan = '{"resourceType":"Condition","id":"syn-1","meta":{"security":[{"code":"SUD"}]},"x":NaN}'
        comma = '{"resourceType":"Condition","id":"syn-1","meta":{"security":[{"code":"ETH"}]},}'

        [ deep, nan, comma ].each do |line|
          assert_nil Part2EgressFilter.call("#{line}\n")
          assert_nil Part2EgressFilter.call("#{condition.to_json}\n#{line}\n")
        end
      end

      test "a line that is not JSON and does not open with a brace or bracket is still unchanged" do
        text = "id,detail\n1,plain {not json}\n2,[bracketed] note\n"

        assert_equal text, Part2EgressFilter.call(text)
      end

      # --- round 3: securityLabel outside a resource refuses like security ----

      test "a Part 2 securityLabel in a Hash that is not a resource is refused" do
        assert_nil Part2EgressFilter.call({ "data" => { "securityLabel" => [ { "coding" => [ { "code" => "SUD" } ] } ] } })
        assert_nil Part2EgressFilter.call({ data: { securityLabel: [ { coding: [ { code: "eth " } ] } ] } })
        assert_nil Part2EgressFilter.call({ "data" => { "securityLabel" => { "code" => "42CFRPart2" } } })
      end

      test "a securityLabel with no Part 2 code in a Hash that is not a resource is returned equal" do
        payload = { "data" => { "securityLabel" => [ { "coding" => [ UNRELATED_LABEL ] } ] } }

        assert_equal payload, Part2EgressFilter.call(payload)
      end

      test "a Bundle entry resource with no resourceType and a Part 2 securityLabel is refused" do
        typeless = { "id" => "syn-doc", "status" => "current", "securityLabel" => [ { "coding" => [ { "system" => ACT_CODE, "code" => "SUD" } ] } ] }
        bundle = bundle_of(entry(condition, mode: "match"), { "fullUrl" => "https://example.test/x/syn-doc", "resource" => typeless })

        assert_nil Part2EgressFilter.call(bundle)
        assert_nil Part2EgressFilter.call(bundle.deep_symbolize_keys)
      end

      test "an NDJSON line that is not a resource and has a Part 2 securityLabel is refused" do
        line = { "id" => "syn-doc", "securityLabel" => [ { "coding" => [ { "code" => "OPIOIDUD" } ] } ] }.to_json

        assert_nil Part2EgressFilter.call("#{condition.to_json}\n#{line}\n")
      end

      test "a pretty-printed JSON document with a Part 2 securityLabel outside a resource is refused" do
        text = JSON.pretty_generate(export_manifest("extension" => { "securityLabel" => [ { "coding" => [ { "code" => "ETH" } ] } ] }))

        assert_nil Part2EgressFilter.call(text)
      end

      test "C-CDA sections with a row whose securityLabel holds a Part 2 code are refused" do
        [
          { code: "F10.20", display: "Synthetic condition", securityLabel: [ { coding: [ { code: "SUD" } ] } ] },
          { code: "F10.20", display: "Synthetic condition", "securityLabel" => [ { "coding" => [ { "code" => "42cfrpart2" } ] } ] },
          { code: "F10.20", display: "Synthetic condition", code_system: nil,
            fhir: { code: "F10.20", display: "Synthetic condition", securityLabel: [ { coding: [ { code: "ETHUD" } ] } ] } }
        ].each do |row|
          assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ])), "#{row.inspect[0, 120]} must refuse"
        end
      end

      # --- round 5: the non-resource rule on a top-level Hash and a document ---

      test "C-CDA sections with a condition row tagged SUD outside security are refused" do
        row = { code: "SYN-1", display: "Synthetic", code_system: nil, meta: { tag: [ { code: "SUD" } ] } }

        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
      end

      test "C-CDA sections with a string-keyed row tagged SUD outside security are refused" do
        row = { "code" => "SYN-1", "display" => "Synthetic", "code_system" => nil, "meta" => { "tag" => [ { "code" => "SUD" } ] } }

        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]).deep_stringify_keys)
      end

      %w[42CFRPart2 ETH SUD ETHUD OPIOIDUD].each do |code|
        %i[allergies conditions medications].each do |list|
          test "C-CDA sections with a #{code} code outside security in #{list} are refused" do
            [ code, " #{code.downcase} " ].each do |value|
              row = { code: "SYN-1", display: "Synthetic", code_system: nil, meta: { tag: [ { code: value } ] } }

              assert_nil Part2EgressFilter.call(ccda_sections(list => [ row ])), "#{value.inspect} in #{list} must refuse"
            end
          end
        end
      end

      test "C-CDA sections with a row whose String leaf is 42CFRPart2 are refused" do
        row = { code: "SYN-1", display: "Synthetic", code_system: nil, note: "42CFRPart2" }

        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
      end

      test "C-CDA sections with a row whose String leaf names 42CFRPart2 in prose are refused" do
        row = { code: "SYN-1", display: "Synthetic", code_system: nil, note: "label 42cfrpart2 applied" }

        assert_nil Part2EgressFilter.call(ccda_sections(medications: [ row ]))
        assert_nil Part2EgressFilter.call(ccda_sections(medications: [ row.stringify_keys ]))
      end

      test "a top-level Hash that is not a resource and has a Part 2 code as a String leaf is refused" do
        assert_nil Part2EgressFilter.call({ "rows" => [ { "x" => [ "N", "OPIOIDUD" ] } ] })
      end

      test "a pretty-printed document that is not a resource and holds a row tagged SUD is refused" do
        text = JSON.pretty_generate({ "rows" => [ { "code" => "x", "meta" => { "tag" => [ { "code" => "SUD" } ] } } ] })

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_nil Part2EgressFilter.call(text)
        assert_nil Part2EgressFilter.call("﻿#{text}"), "after a byte order mark"
      end

      test "a pretty-printed document that is not a resource and holds a Part 2 code as a String leaf is refused" do
        text = JSON.pretty_generate({ "rows" => [ { "label" => "eth", "n" => 1 } ] })

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_nil Part2EgressFilter.call(text)
        assert_nil Part2EgressFilter.call("﻿#{text}"), "after a byte order mark"
      end

      test "a pretty-printed document that is not a resource and names 42CFRPart2 in a longer string is refused" do
        text = JSON.pretty_generate({ "rows" => [ { "note" => "label 42cfrpart2 applied", "n" => 1 } ] })

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_nil Part2EgressFilter.call(text)
        assert_nil Part2EgressFilter.call("﻿#{text}"), "after a byte order mark"
      end

      # Guards: the non-resource rule must not over-refuse.

      test "C-CDA sections whose display is prose naming a short code are returned equal" do
        sections = ccda_sections(
          conditions: [ { code: "SYN-1", display: "County SUD Clinic follow-up", code_system: nil } ],
          medications: [ { "code" => "SYN-M", "display" => "METHOD of ETH-free preparation", "code_system" => nil } ]
        )

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      test "a pretty-printed document that is not a resource and names a short code in prose is unchanged" do
        text = JSON.pretty_generate({ "rows" => [ { "note" => "County SUD Clinic", "code" => "N", "n" => 1 }, [ 1, "METHOD" ] ] })

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_equal text, Part2EgressFilter.call(text)
        assert_equal "﻿#{text}", Part2EgressFilter.call("﻿#{text}"), "after a byte order mark"
      end

      test "a pretty-printed unlabelled resource whose clinical coding is ETH is unchanged" do
        resource = condition("code" => { "coding" => [ { "system" => "http://example.test/synthetic", "code" => "ETH" } ] })
        text = JSON.pretty_generate(resource)

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_equal text, Part2EgressFilter.call(text)
      end

      # --- round 6: the non-resource rule's reach -----------------------------
      #
      # A. The whole-leaf scan does not descend into a nested resource (a
      # resource is held to the label rules) and does not treat a value under
      # a human-text or demographic key as a code. 42CFRPart2 still refuses
      # anywhere. B. A `meta` key in a Hash that is not a resource cannot
      # carry the notice, so a Part 2 code under it refuses. C. A top-level
      # Array gets the non-resource rule.

      HUMAN_TEXT_KEYS = %w[display text name family given prefix suffix address line city district state postalCode country].freeze

      COLLIDING_PATIENT = {
        "resourceType" => "Patient", "id" => "syn-pt",
        "name" => [ { "family" => "Sud", "given" => [ "Eth" ] } ],
        "address" => [ { "country" => "ETH" } ]
      }.freeze

      CLINICAL_ETH = { "coding" => [ { "system" => "http://example.test/synthetic", "code" => "ETH" } ] }.freeze

      RAW_TAGGED_ROW = { "code" => "F11.20", "meta" => { "tag" => [ { "code" => "SUD" } ] } }.freeze

      test "C-CDA sections whose patient name and address collide with short codes are returned equal" do
        patient = { dfn: "1", name: { family: "SUD", given: "Eth" }, dob: nil, sex: "F", address: { city: "Sud", country: "ETH" } }
        sections = ccda_sections(patient: patient)
        before = sections.deep_dup

        result = Part2EgressFilter.call(sections)

        assert_equal sections, result, "demographics are not labels"
        assert_equal before, sections, "the input must not be mutated"
      end

      test "string-keyed C-CDA sections whose patient name and address collide with short codes are returned equal" do
        patient = { dfn: "1", name: { family: "SUD", given: "Eth" }, dob: nil, sex: "F", address: { city: "Sud", country: "ETH" } }
        sections = ccda_sections(patient: patient).deep_stringify_keys

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      test "C-CDA sections whose patient holds an unlabelled Patient resource with colliding demographics are returned equal" do
        sections = ccda_sections(patient: ccda_sections[:patient].merge(fhir: COLLIDING_PATIENT.deep_dup))

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      test "C-CDA sections whose row holds an unlabelled Patient resource with colliding demographics are returned equal" do
        %i[allergies conditions medications].each do |list|
          row = { code: "SYN-1", display: "Synthetic", code_system: nil, fhir: COLLIDING_PATIENT.deep_dup }
          sections = ccda_sections(list => [ row ])

          assert_equal sections, Part2EgressFilter.call(sections), "a nested unlabelled resource in #{list}"
        end
      end

      test "C-CDA sections holding a symbol-keyed unlabelled Patient resource with colliding demographics are returned equal" do
        resource = { resourceType: "Patient", id: "syn-pt", name: [ { family: "Sud", given: [ "Eth" ] } ], address: [ { country: "ETH" } ] }
        sections = ccda_sections(patient: ccda_sections[:patient].merge(fhir: resource))

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      test "C-CDA sections whose condition row holds an unlabelled resource with clinical coding ETH are returned equal" do
        # The same rule as "a clinical coding outside meta.security is not a
        # Part 2 label": a nested resource is held to the label rules.
        row = { code: "SYN-1", display: "Synthetic", code_system: nil, fhir: condition("code" => CLINICAL_ETH.deep_dup) }
        sections = ccda_sections(conditions: [ row ])
        before = sections.deep_dup

        result = Part2EgressFilter.call(sections)

        assert_equal sections, result
        assert_equal before, sections, "the input must not be mutated"
      end

      test "C-CDA sections whose allergy row display is ETH are returned equal" do
        sections = ccda_sections(allergies: [ { code: "SYN-A", display: "ETH", code_system: nil } ])

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      test "C-CDA sections whose string-keyed row display is a short code are returned equal" do
        sections = ccda_sections(medications: [ { "code" => "SYN-M", "display" => " sud ", "code_system" => nil } ])

        assert_equal sections, Part2EgressFilter.call(sections)
      end

      HUMAN_TEXT_KEYS.each do |key|
        test "a short code under the human-text key #{key} in a C-CDA row is not a label" do
          [ key, key.to_sym ].each do |row_key|
            [ "SUD", [ "Eth" ] ].each do |value|
              sections = ccda_sections(conditions: [ { code: "SYN-1", code_system: nil, row_key => value } ])

              assert_equal sections, Part2EgressFilter.call(sections), "#{row_key.inspect} => #{value.inspect} must not refuse"
            end
          end
        end
      end

      test "a pretty-printed document that is not a resource and holds an unlabelled resource with clinical coding ETH is unchanged" do
        resource = condition("code" => CLINICAL_ETH.deep_dup)
        text = JSON.pretty_generate(export_manifest("output" => [ { "type" => "Condition", "resource" => resource } ]))

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_equal text, Part2EgressFilter.call(text)
      end

      # Guards for A: what the narrowed scan still refuses.

      test "C-CDA sections with a raw row whose code is SUD are refused" do
        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ { code: "SUD", display: "Synthetic", code_system: nil } ]))
        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ { "code" => " sud ", "display" => "Synthetic" } ]))
      end

      test "C-CDA sections with a raw row tagged ETH in meta are refused" do
        row = { code: "SYN-1", display: "Synthetic", code_system: nil, meta: { tag: [ { code: "ETH" } ] } }

        assert_nil Part2EgressFilter.call(ccda_sections(allergies: [ row ]))
      end

      test "C-CDA sections whose patient family name is 42CFRPart2 are refused" do
        # 42CFRPart2 refuses anywhere, a human-text key included.
        [ { family: "42CFRPart2", given: "PATIENT" }, { "family" => "x 42cfrpart2 y", "given" => "PATIENT" } ].each do |name|
          patient = ccda_sections[:patient].merge(name: name)

          assert_nil Part2EgressFilter.call(ccda_sections(patient: patient)), "#{name.inspect} must refuse"
        end
      end

      test "C-CDA sections whose row display is 42CFRPart2 are refused" do
        assert_nil Part2EgressFilter.call(ccda_sections(allergies: [ { code: "SYN-A", display: "42CFRPart2", code_system: nil } ]))
      end

      test "a short code under another key beside a human-text key is still refused" do
        row = { code: "SYN-1", display: "ETH", code_system: nil, label: "SUD" }

        assert_nil Part2EgressFilter.call(ccda_sections(conditions: [ row ]))
      end

      test "C-CDA sections with colliding demographics and a labelled nested resource are still refused" do
        patient = { dfn: "1", name: { family: "SUD", given: "Eth" }, dob: nil, sex: "F", address: { country: "ETH" },
                    fhir: COLLIDING_PATIENT.merge("meta" => { "security" => [ { "code" => "SUD" } ] }) }

        assert_nil Part2EgressFilter.call(ccda_sections(patient: patient))
      end

      # B. A raw row inside a resource.

      test "a Bundle whose entry resource is a raw row tagged SUD in meta is refused" do
        bundle = { "resourceType" => "Bundle", "type" => "searchset", "entry" => [ { "resource" => RAW_TAGGED_ROW.deep_dup } ] }

        assert_nil Part2EgressFilter.call(bundle)
        assert_nil Part2EgressFilter.call(bundle.deep_symbolize_keys), "symbol keys"
      end

      test "an NDJSON line that is a Bundle whose entry resource is a raw row tagged SUD in meta is refused" do
        bundle = { "resourceType" => "Bundle", "type" => "searchset", "entry" => [ { "resource" => RAW_TAGGED_ROW.deep_dup } ] }

        assert_nil Part2EgressFilter.call(bundle.to_json)
        assert_nil Part2EgressFilter.call("#{condition.to_json}\n#{bundle.to_json}\n")
      end

      test "a pretty-printed Bundle whose entry resource is a raw row tagged SUD in meta is refused" do
        bundle = { "resourceType" => "Bundle", "type" => "searchset", "entry" => [ { "resource" => RAW_TAGGED_ROW.deep_dup } ] }
        text = JSON.pretty_generate(bundle)

        assert_operator text.lines.size, :>, 1, "test data must be a multi-line document"
        assert_nil Part2EgressFilter.call(text)
      end

      test "a resource holding a raw Hash with a normalised Part 2 code under meta is refused" do
        resource = { "resourceType" => "Condition", "id" => "syn-1", "raw" => { "meta" => { "tag" => [ { "code" => "ethud " } ] } } }

        assert_nil Part2EgressFilter.call(resource)
      end

      test "a symbol-keyed resource holding a raw Hash with a normalised Part 2 code under meta is refused" do
        resource = { resourceType: "Condition", id: "syn-1", raw: { meta: { tag: [ { code: "ethud " } ] } } }

        assert_nil Part2EgressFilter.call(resource)
      end

      %w[42CFRPart2 ETH SUD ETHUD OPIOIDUD].each do |code|
        test "a #{code} code under the meta of a raw Hash inside a resource is refused" do
          assert_nil Part2EgressFilter.call(condition("raw" => { "meta" => { "tag" => [ { "code" => code } ] } }))
          assert_nil Part2EgressFilter.call(condition("raw" => [ { "nested" => { "meta" => { "profile" => [ code.downcase ] } } } ])), "deeper"
        end
      end

      # Guards for B.

      test "a Bundle whose entry holds an unlabelled resource with an ordinary meta.tag is returned equal" do
        bundle = bundle_of(entry(condition("meta" => { "tag" => [ { "code" => "syn" } ] }), mode: "match"))

        result = Part2EgressFilter.call(bundle)

        assert_equal bundle, result
        refute_noticed result
        refute_noticed result["entry"][0]["resource"]
      end

      test "a symbol-keyed Bundle whose entry holds an unlabelled resource with an ordinary meta.tag is returned equal" do
        bundle = {
          resourceType: "Bundle", type: "searchset",
          entry: [ { resource: { resourceType: "Condition", id: "syn-1", meta: { tag: [ { code: "syn" } ] } } } ]
        }

        assert_equal bundle, Part2EgressFilter.call(bundle)
      end

      test "a resource holding a raw Hash whose meta has no Part 2 code is returned equal" do
        resource = condition("raw" => { "code" => "F11.20", "meta" => { "tag" => [ { "code" => "syn" } ], "versionId" => "1" } })

        result = Part2EgressFilter.call(resource)

        assert_equal resource, result
        refute_noticed result
      end

      test "a resource's own meta.tag and meta.security behave as before beside a raw Hash" do
        raw = { "code" => "F11.20", "meta" => { "tag" => [ { "code" => "syn" } ] } }

        assert_nil Part2EgressFilter.call(condition("meta" => { "tag" => [ { "code" => "SUD" } ] }, "raw" => raw))

        labelled = condition("meta" => { "security" => [ PART2_LABEL ], "tag" => [ { "code" => "syn" } ] }, "raw" => raw)
        result = Part2EgressFilter.call(labelled)
        assert_noticed result
        assert_equal labelled, without_notice(result)
      end

      # C. A top-level Array.

      test "a top-level Array holding a raw row tagged SUD in meta is refused" do
        assert_nil Part2EgressFilter.call([ { code: "F11.20", meta: { tag: [ { code: "SUD" } ] } } ])
      end

      test "a top-level Array holding a string-keyed raw row tagged SUD in meta is refused" do
        assert_nil Part2EgressFilter.call([ { "code" => "SYN-1" }, RAW_TAGGED_ROW.deep_dup ])
      end

      test "an unlabelled top-level Array is returned as the same object" do
        rows = [ { code: "SYN-1", display: "x" } ]

        assert_same rows, Part2EgressFilter.call(rows)
      end

      private

      # The audit_log.csv of an EHI export: the service's own header, then a
      # row per Description. Synthetic values only.
      def audit_csv(descriptions)
        rows = descriptions.each_with_index.map do |description, index|
          CSV.generate_line([ "2026-01-0#{index + 1}T00:00:00Z", "rest", "R", "0", "Patient", "syn-pt", description ])
        end
        "#{EhiExportService.audit_csv_header_line}\n#{rows.join}"
      end

      def export_manifest(overrides = {})
        {
          "transactionTime" => "2026-01-01T00:00:00Z",
          "request" => "https://example.test/lakeraven-ehr/$export",
          "requiresAccessToken" => true,
          "output" => [ { "type" => "Condition", "url" => "https://example.test/files/syn-1.ndjson" } ],
          "error" => []
        }.merge(overrides)
      end

      def document_reference(overrides = {})
        {
          "resourceType" => "DocumentReference", "id" => "syn-doc", "status" => "current",
          "subject" => { "reference" => "Patient/syn-pt" },
          "content" => [ { "attachment" => { "contentType" => "text/plain", "title" => "Synthetic note" } } ]
        }.merge(overrides)
      end

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
