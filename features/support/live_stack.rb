# frozen_string_literal: true

# cucumber --profile stack (#962). A @live scenario is reported as run only
# with evidence that it ran against the stack as the persona (LiveStack.verdict);
# otherwise it is skipped as not run, never passed. A step whose RPC the stack
# declined has already raised LiveStack::NotRun, a skip. A scenario that
# stubbed a gateway (features/support/gateway_stubs.rb) is not run either.
#
# A run in which no @live scenario ran is not a green run (#1179): absence of
# data is never verification. It says so in one line, naming the first reason
# a scenario was not run, and exits non-zero. A run in which one ran keeps
# cucumber's own exit code.
if LIVE_STACK
  stack_run = { ran: 0, reason: nil }

  After do |scenario|
    if scenario.status == :skipped
      stack_run[:reason] ||= @live_stack_reason || LiveStack.take_evidence.reasons.first ||
                             (LIVE_STACK.reason unless LIVE_STACK.ready?)
    else
      stack_run[:ran] += 1
    end
  end

  at_exit do
    next if stack_run[:ran].positive?

    reason = stack_run[:reason] || (LIVE_STACK.reason unless LIVE_STACK.ready?) || "no @live scenario was selected"
    warn "[stack] no @live scenario ran: #{reason}"
    status = $!.is_a?(SystemExit) ? $!.status : 0
    exit(status.zero? ? 1 : status)
  end

  if LIVE_STACK.ready?
    Before do |scenario|
      LiveStack.take_evidence
      @live_stack_location = scenario.location
      @live_stack_last_step = scenario.test_steps.reject(&:hook?).last
    end

    AfterStep do |_result, step|
      next unless step.id == @live_stack_last_step&.id

      reason = LiveStack.verdict(evidence: LiveStack.take_evidence, client: RpmsRpc.configuration.client,
                                 stack_client: LIVE_STACK_CLIENT, persona_duz: LIVE_STACK.persona_duz)
      # A stubbed gateway answered in place of the stack.
      reason ||= "a gateway was stubbed" unless @gateway_stubs.to_a.empty?
      if reason
        @live_stack_reason = reason
        warn "[stack] #{@live_stack_location}: not run: #{reason}"
        skip_this_scenario("not run: #{reason}")
      end
    end
  else
    Before("@live") do |scenario|
      warn "[stack] #{scenario.location}: #{LiveStack.not_run_message(LIVE_STACK)}"
      skip_this_scenario(LiveStack.not_run_message(LIVE_STACK))
    end
  end
end
