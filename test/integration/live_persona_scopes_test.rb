# frozen_string_literal: true

require "test_helper"
require_relative "../support/demo_persona_keys"

# Live (#578): each demo persona signs on to a real RPMS and gets the scopes
# its held keys and options grant, the same ones PersonaScopesTest computes from the key
# sets the build files. Skipped unless LIVE_RPMS=1 (see test_helper.rb), e.g.
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9110 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_persona_scopes_test.rb
#
# The pairs are the build's published demo pairs (rpms-ops SEEDPERS).
class LivePersonaScopesTest < ActiveSupport::TestCase
  PAIRS = {
    "PROFILE,MD" => %w[PMD123 PMD123!!],
    "PROFILE,RN" => %w[PRN123 PRN123!!],
    "PROFILE,MA" => %w[PMA123 PMA123!!],
    "PROFILE,REG" => %w[PREG123 PREG123!!],
    "PROFILE,SCHED" => %w[PSCH123 PSCH123!!]
  }.freeze

  setup { skip "live: set LIVE_RPMS=1 and a broker" unless defined?(LIVE_RPMS) && LIVE_RPMS }

  # One process holds one broker identity (rpms-rpc#234): sign the run's
  # persona back on for whatever runs next.
  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS }

  PAIRS.each do |persona, (access, verify)|
    test "#{persona} signs on and gets exactly the scopes its held keys and options grant" do
      result = Lakeraven::EHR::AuthenticationService.new.authenticate(access_code: access, verify_code: verify)
      assert result.success?, "#{persona}: #{result.error}"
      assert_equal persona, result.value[:name]

      expected_keys = Lakeraven::EHR::Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA.fetch(persona))
      assert_equal expected_keys.sort, result.value[:security_keys].sort, "#{persona}: the keys RPMS reported"
      expected_options = DemoPersonaKeys::OPTIONS_BY_PERSONA.fetch(persona)
      assert_equal expected_options.sort, result.value[:options].sort, "#{persona}: the options RPMS reported"
      assert_equal Lakeraven::EHR::SessionScopePolicy.scopes_for(security_keys: expected_keys, options: expected_options),
                   Lakeraven::EHR::SessionScopePolicy.scopes_for(security_keys: result.value[:security_keys], options: result.value[:options])
    end
  end
end
