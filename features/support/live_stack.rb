# frozen_string_literal: true

# cucumber --profile stack (#962). A @live scenario the stack cannot run is
# reported as not run (skipped), never as passed: when the stack is not ready
# at all, or when the persona's context refuses an RPC the scenario made.
if LIVE_STACK
  if LIVE_STACK.ready?
    Before { LiveStack.take_refusals }

    AfterStep do
      names = LiveStack.take_refusals
      skip_this_scenario("not run: #{names.join(', ')} refused in the persona's context") unless names.empty?
    end
  else
    Before("@live") { skip_this_scenario(LiveStack.not_run_message(LIVE_STACK)) }
  end
end
