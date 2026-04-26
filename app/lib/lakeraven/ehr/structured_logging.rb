# frozen_string_literal: true

module Lakeraven
  module EHR
    module StructuredLogging
      extend ActiveSupport::Concern

      private

      def log_operation(operation, service_request, extra = {}, &block)
        context = build_context(service_request, extra)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        log_info("#{operation}_started", context)

        result = yield if block_given?

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
        log_info("#{operation}_completed", context.merge(duration_ms: duration_ms))
        result
      rescue => e
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
        log_error("#{operation}_failed", context.merge(
          duration_ms: duration_ms,
          error: e.class.name,
          error_message: PhiSanitizer.sanitize_message(e.message)
        ))
        raise
      end

      def log_info(event, data = {})
        Rails.logger.info(format_log_message(event, data))
      end

      def log_warn(event, data = {})
        Rails.logger.warn(format_log_message(event, data))
      end

      def log_error(event, data = {})
        Rails.logger.error(format_log_message(event, data))
      end

      def build_context(service_request, extra = {})
        context = {
          service_request_ien: service_request&.ien,
          patient_id_hash: PhiSanitizer.hash_identifier(service_request&.patient_dfn),
          requesting_provider_ien: service_request&.requesting_provider_ien
        }.compact
        sanitized_extra = PhiSanitizer.sanitize_hash(extra)
        context.merge(sanitized_extra)
      end

      def format_log_message(event, data)
        parts = [ event.to_s ]
        if data.any?
          formatted_data = data.map { |k, v| "#{k}=#{v}" }.join(" ")
          parts << formatted_data
        end
        parts.join(" | ")
      end
    end
  end
end
