# frozen_string_literal: true

# A per-action skip. The parent enforces forgery protection, so a callback
# object still exists on the class — but it does not run for :create. A
# membership scan of the callback chain sees it and answers "protected"; the
# request is not actually verified. Must be refused.
class ConditionalSkipProbeController < CsrfProbeController
  skip_before_action :verify_authenticity_token, only: :create
end
