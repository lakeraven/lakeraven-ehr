# frozen_string_literal: true

module Lakeraven
  module EHR
    class VitalsEntryService
      Result = Struct.new(:success, :measurements, :error, :raw, keyword_init: true) do
        def success? = success
      end

      # Gateway is constructor-injected so tests can pass an explicit fake
      # without mutating shared global state. Default is the production gateway.
      def initialize(dfn:, visit_string:, measurements:, provider_duz: nil,
                     gateway: VitalGateway)
        @dfn = dfn
        @visit_string = visit_string
        @measurements = measurements || []
        @provider_duz = provider_duz
        @gateway = gateway
      end

      def save
        return failure(:invalid_input) if @dfn.nil? || @visit_string.nil?
        return failure(:no_measurements) if @measurements.empty?

        raw = @gateway.add(@dfn, @visit_string, @measurements, provider_duz: @provider_duz)
        # Guard against gateway returning nil or a non-hash — surface as
        # :gateway_error rather than NoMethodError on raw[:success].
        return failure(:gateway_error, raw: raw) unless raw.is_a?(Hash) && raw[:success]

        # The underlying RPC does not return per-measurement IENs in its
        # response; the engine treats @measurements (what it submitted and
        # the gateway confirmed saved via success=true) as the canonical
        # record of what was recorded.
        Result.new(success: true, measurements: @measurements, raw: raw)
      end

      private

      def failure(reason, raw: nil)
        Result.new(success: false, measurements: [], error: reason, raw: raw)
      end
    end
  end
end
