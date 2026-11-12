# frozen_string_literal: true

# cucumber --profile stack (#962). A @live scenario is reported as run only
# with evidence that it ran against the stack as the persona (LiveStack.verdict);
# otherwise it is skipped as not run, never passed. A step whose RPC the stack
# declined has already raised LiveStack::NotRun, a skip.
if LIVE_STACK
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
      if reason
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
