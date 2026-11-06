# frozen_string_literal: true

module Lakeraven
  module EHR
    # Chart, consent, and kiosk responses are PHI. A shared cache or the
    # back button must not keep them. Prepended so a halted before_action
    # (the kiosk redirect) still leaves the header on the response.
    module PhiPageCache
      extend ActiveSupport::Concern

      included do
        prepend_before_action :send_no_store_cache_header
      end

      private

      def send_no_store_cache_header
        response.headers["Cache-Control"] = "no-store"
      end
    end
  end
end
