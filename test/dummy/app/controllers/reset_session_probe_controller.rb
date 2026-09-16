# frozen_string_literal: true

# Another non-rejecting strategy: an unverified request resets the session
# instead of raising. The forged write proceeds, and @current_token — already
# resolved by authenticate_smart_token! — survives the reset. Must be refused.
class ResetSessionProbeController < CsrfProbeController
  protect_from_forgery with: :reset_session
end
