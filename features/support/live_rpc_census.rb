# frozen_string_literal: true

# LIVE_RPMS only: records, per scenario, which RPCs reached the real broker,
# so a run can say how many scenarios exercised RPMS rather than a stub.
# Written to LIVE_RPC_CENSUS (one JSON line per scenario).
if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPC_CENSUS"]
  module LiveRpcCensus
    CALLS = []

    def call_rpc_raw(rpc_name, *params)
      CALLS << rpc_name.to_s
      super
    end
  end
  RpmsRpc::CiaClient.prepend(LiveRpcCensus)

  Before { LiveRpcCensus::CALLS.clear }

  After do |scenario|
    File.open(ENV["LIVE_RPC_CENSUS"], "a") do |f|
      f.puts({ location: scenario.location.to_s, status: scenario.status.to_s, rpcs: LiveRpcCensus::CALLS.tally }.to_json)
    end
  end
end
