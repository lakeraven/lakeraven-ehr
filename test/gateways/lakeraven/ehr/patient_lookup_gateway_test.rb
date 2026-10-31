# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientLookupGatewayTest < ActiveSupport::TestCase
      # What RpmsRpc::Patient.lookup answers, recorded per call.
      class Lookup
        attr_reader :calls

        def initialize(rows = [], raises: nil)
          @rows = rows
          @raises = raises
          @calls = []
        end

        def lookup(text, **opts)
          @calls << [ text, opts ]
          raise @raises if @raises

          @rows
        end
      end

      MOUSE = { dfn: 3, name: "MOUSE,MICKEY M", hrn: "1001", dob: "FEB 14,1910", dod: nil, inactive: false }.freeze

      test "asks for inactive charts too, and for a reply it can read" do
        via = Lookup.new([ MOUSE ])
        PatientLookupGateway.find("MOUSE", via: via)

        assert_equal [ [ "MOUSE", { include_inactive: true, require_response: true } ] ], via.calls
      end

      test "a match carries the health record number, the date of birth and the status" do
        match = PatientLookupGateway.find("MOUSE", via: Lookup.new([ MOUSE ])).sole

        assert_equal 3, match.dfn
        assert_equal "1001", match.hrn
        assert_equal Date.new(1910, 2, 14), match.dob
        assert_equal "Active", match.status
      end

      test "an inactive chart and a deceased patient say so" do
        rows = [ MOUSE.merge(dfn: 5, inactive: true), MOUSE.merge(dfn: 6, dod: "MAR 1,2020") ]
        inactive, deceased = PatientLookupGateway.find("MOUSE", via: Lookup.new(rows))

        assert_equal "Inactive", inactive.status
        assert_equal "Deceased", deceased.status
        assert_equal Date.new(2020, 3, 1), deceased.dod
      end

      test "a date of birth narrows the matches to the patients born on it" do
        rows = [ MOUSE, MOUSE.merge(dfn: 9, dob: "JAN 1,1950") ]
        found = PatientLookupGateway.find("MOUSE", dob: Date.new(1910, 2, 14), via: Lookup.new(rows))

        assert_equal [ 3 ], found.map(&:dfn)
      end

      test "a lookup that fails raises, and never reads as no match" do
        via = Lookup.new(raises: RpmsRpc::Client::RpcError.new("4 Access denied"))

        assert_raises(RpmsRpc::Client::RpcError) { PatientLookupGateway.find("MOUSE", via: via) }
      end

      test "an empty search asks nothing" do
        via = Lookup.new([ MOUSE ])

        assert_empty PatientLookupGateway.find("  ", via: via)
        assert_empty via.calls
      end

      # Through the gem, with the reply framed as AGGPTLKP's global array arrives
      # (the typed header, $C(30)-separated records, the $C(31) end): the row a
      # live e9b78c8 build answered for MOUSE.
      test "decodes the live reply shape through RpmsRpc::Patient.lookup" do
        header = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"
        RpmsRpc.client.seed_text(:patient_lookup_agg, "MOUSE", "\x00#{header}\x1e3^MOUSE,MICKEY M^1001^XXX-XX-9999^FEB 14,1910^^N^^N\x1e\x1f")

        match = PatientLookupGateway.find("MOUSE").sole

        assert_equal [ 3, "MOUSE,MICKEY M", "1001", Date.new(1910, 2, 14), "Active" ],
                     [ match.dfn, match.name, match.hrn, match.dob, match.status ]
      end
    end
  end
end
