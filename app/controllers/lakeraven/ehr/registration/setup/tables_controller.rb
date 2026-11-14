# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      module Setup
        # The setup tables the signed-in user may open, each by its own
        # capability. Asks RPMS nothing.
        class TablesController < BaseController
          before_action -> { require_capability!("registration.setup") }

          rate_limit only: %i[index]

          # GET /registration/setup
          def index; end
        end
      end
    end
  end
end
