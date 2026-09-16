# frozen_string_literal: true

# Unprotected: same superclass, forgery protection skipped. The discriminator
# is the PROTECTION, not the class name, so this must NOT inherit write
# capability from its parent.
class CsrfDisabledProbeController < CsrfProbeController
  skip_before_action :verify_authenticity_token
end
