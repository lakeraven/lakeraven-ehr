# frozen_string_literal: true

module Lakeraven
  module EHR
    # The local, development-only synthetic demo: the chart opens with no
    # token and the demo walk-in page answers. ChartsController and
    # DemoVisitsController both ask this one question, so the chart links to
    # the walk-in page only where that page would answer.
    #
    # Guarded on development? so it can never apply in test or production,
    # and on the mock-RPC flag so it can never front a real backend.
    module LocalChartDemo
      def self.open?
        Rails.env.development? && ENV["CHART_DEMO_OPEN"] == "1" && ENV["SPIKE_MOCK_RPC"] == "1"
      end
    end
  end
end
