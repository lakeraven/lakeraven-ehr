# frozen_string_literal: true

module Lakeraven
  module EHR
    # Records a purpose of visit (POV / visit diagnosis) against an open
    # encounter. The visit cannot be credited or closed without one.
    class PovEntryService
      Result = Struct.new(:success, :ien, :error, :raw, keyword_init: true) do
        def success? = success
      end

      # Gateway is constructor-injected so tests can pass an explicit fake
      # without mutating shared global state. Default is the production gateway.
      def initialize(dfn:, visit_ien:, diagnosis_code:, narrative:,
                     modifiers: {}, gateway: PovGateway)
        @dfn = dfn
        @visit_ien = visit_ien
        @diagnosis_code = diagnosis_code
        @narrative = narrative
        @modifiers = modifiers
        @gateway = gateway
      end

      def save
        return failure(:invalid_input) if @dfn.nil? || @visit_ien.nil?
        return failure(:missing_diagnosis) if @diagnosis_code.to_s.strip.empty?

        raw = @gateway.add(@dfn, @visit_ien, @diagnosis_code,
          narrative: @narrative, modifiers: @modifiers)
        return failure(:gateway_error, raw: raw) unless raw.is_a?(Hash) && raw[:success]

        Result.new(success: true, ien: raw[:ien], raw: raw)
      end

      private

      def failure(reason, raw: nil)
        Result.new(success: false, error: reason, raw: raw)
      end
    end
  end
end
