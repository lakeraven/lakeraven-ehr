# frozen_string_literal: true

# Behaviour fingerprint for SessionScopePolicy, used by bin/mutation-gate to
# recognise EQUIVALENT mutants — source edits that cannot change what the policy
# does, and which therefore no test can ever kill.
#
# Two exist in this table today: `write: read` is a no-op wherever a key already
# writes everything it reads (chs_approve, consult_manager, eligibility_verify),
# and `read: []` is a no-op wherever the read list is already empty (the
# behavioural-health keys, whose emptiness is the #494 gap). Reporting those as
# survivors would train everyone to ignore the gate's output.
#
# Deliberately avoids booting Rails: 57 mutants x a Rails boot is minutes, and
# the policy needs nothing from the framework.

require "json"
require "rpms_rpc/security_keys"

module Lakeraven
  module EHR
  end
end

load File.expand_path("../../../app/services/lakeraven/ehr/session_scope_policy.rb", __dir__)

policy = Lakeraven::EHR::SessionScopePolicy

fingerprint = policy::KEY_SCOPES.keys.sort.to_h do |key|
  [ key.to_s, policy.scopes_for(security_keys: [ key ]).sort ]
end

# The empty set and the all-keys union are part of the behaviour too: a mutation
# to the guard or to all_scopes would otherwise fingerprint identically.
fingerprint["__none__"] = policy.scopes_for(security_keys: [])
fingerprint["__unmodelled__"] = policy.scopes_for(security_keys: [ :zz_not_modelled ])
fingerprint["__all__"] = policy.all_scopes.sort

puts JSON.generate(fingerprint)
