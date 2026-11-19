# frozen_string_literal: true

require "test_helper"
require "rpms_rpc"

# Synthetic wire regression, not captured replies or live FileMan proof.
# BSDX RESOURCE USER's B index repeats the resource pointer for each member.
# A flat FROM resumes beyond that value, losing the rest of a duplicate group.
# The # traversal uses unique record numbers instead (also exercised by
# test/live/coverage_write_live_test.rb with FROM=(ien-1), XREF="#").
class ClinicUsersPaginationGatewayTest < ActiveSupport::TestCase
  class MembershipClient
    attr_reader :calls

    def initialize(count)
      @calls = []
      @rows = [ [ 1, 1, 900, "OTHER,BEFORE", 0, 0, 0, 0 ] ]
      count.times do |index|
        @rows << [ index + 2, 7, 1000 + index, format("MEMBER,%03d", count - index), 1, 0, 1, 0 ]
      end
      @rows << [ count + 2, 9, 901, "OTHER,AFTER", 0, 0, 0, 0 ]
    end

    def with_context(_name)
      yield
    end

    def call_rpc(rpc, params)
      raise "Unexpected RPC #{rpc}" unless rpc == "DDR LISTER"
      raise "Unexpected file #{params['FILE']}" unless params["FILE"] == "9002018.15"
      raise "Unexpected paging loop" if @calls.length > 10

      @calls << params
      # LIST^DIC's default B traversal uses .01 (resource pointer). Its
      # secondary IEN disambiguates duplicates, but a flat FROM lacks it.
      column = params["XREF"] == "#" ? 0 : 1
      rows = @rows.sort_by { |row| [ row[column], row[0] ] }
      rows = rows.select { |row| row[column] > params["FROM"].to_i } if params["FROM"]
      page = rows.take(Integer(params.fetch("MAX")))
      reply = []
      if rows.length > page.length
        last = page.last
        reply.concat([ "[Misc]", "MORE^#{last[column]}^#{last[0]}" ])
      end
      reply + [ "[Data]" ] + page.map { |row| row.join("^") }
    end
  end

  [ 100, 101, 205 ].each do |count|
    test "the pinned gem supplies all #{count} users to the host gateway" do
      client = MembershipClient.new(count)
      RpmsRpc.with_client(client) do
        result = Lakeraven::EHR::ClinicUsersGateway.read({ id: 7 })
        assert_equal :available, result.status
        assert_equal count, result.total
        assert_equal (2..count + 1).to_a, result.users.map { |user| user[:id] }.sort
        assert_equal result.users.map { |user| user[:name] }.sort, result.users.map { |user| user[:name] }

        filtered = Lakeraven::EHR::ClinicUsersGateway.read({ id: 7 }, query: "member,001")
        assert_equal count, filtered.total
        assert_equal [ count + 1 ], filtered.users.map { |user| user[:id] }
      end
    end
  end
end
