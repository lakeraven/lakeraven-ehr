# frozen_string_literal: true

# The standard idiom for a JSON-accepting controller: a NON-REJECTING forgery
# strategy. Rails retains the callback object and it "runs", but an unverified
# request is handled by nullifying the session rather than by raising — so the
# forged write reaches the action. A membership test cannot tell this apart
# from a rejecting strategy (both seats, F1). A session-derived write must be
# refused here.
class NullSessionProbeController < CsrfProbeController
  protect_from_forgery with: :null_session
end
