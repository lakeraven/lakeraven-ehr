# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

module Lakeraven
  module EHR
    # FHIR client for an external enrollment service.
    #
    # Eligibility is fail-closed: a response is enrolled or not_enrolled only
    # when it is a complete CoverageEligibilityResponse with an explicit
    # inforce flag. Anything else (malformed body, missing outcome, transport
    # failure) is error or pending, never a coverage answer. Pending checks
    # are not cached. Terminal answers are cached under a digest so the raw
    # patient identifier is not the key. Logs and errors omit the patient
    # identifier, the bearer token, and the request body.
    #
    # The bearer token defaults from LAKERAVEN_ENROLLMENT_FHIR_TOKEN.
    # EnrollmentEligibilityRetryJob reads that same variable; it is not put
    # on the job. LAKERAVEN_ENROLLMENT_FHIR_BASE_URL is the fallback host
    # when a retry runs without the URL captured from the original client.
    class EnrollmentFHIRClient
      class ClientError < StandardError; end

      # Raised by the retry job when a later attempt is still pending.
      class Unavailable < StandardError; end

      # Net::HTTP transport. Tests inject an object with the same #post and
      # #get interface; each returns an object with #code and #body.
      class Http
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 15

        def post(url, body:, headers:)
          perform(url, Net::HTTP::Post, headers) { |request| request.body = body }
        end

        def get(url, headers:)
          perform(url, Net::HTTP::Get, headers)
        end

        private

        def perform(url, request_class, headers)
          uri = URI(url)
          request = request_class.new(uri)
          headers.each { |key, value| request[key] = value }
          yield request if block_given?
          issue(uri, request)
        end

        def issue(uri, request)
          Net::HTTP.start(
            uri.hostname,
            uri.port,
            use_ssl: true,
            open_timeout: OPEN_TIMEOUT,
            read_timeout: READ_TIMEOUT
          ) do |http|
            http.request(request)
          end
        end
      end

      FHIR_MEDIA_TYPE = "application/fhir+json"
      DEFAULT_TTL = 24.hours
      DEFAULT_ATTEMPTS = 3
      BACKOFF_SECONDS = 0.5
      RETRYABLE_NETWORK_ERRORS = [
        SystemCallError,
        SocketError,
        IOError,
        Timeout::Error,
        OpenSSL::SSL::SSLError
      ].freeze

      def self.from_environment(base_url: nil)
        url = base_url.presence || ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"].presence
        return if url.blank?

        new(base_url: url, cache: (Rails.cache if defined?(Rails.cache)), schedule_retry: false)
      end

      def initialize(
        base_url:,
        token: ENV["LAKERAVEN_ENROLLMENT_FHIR_TOKEN"],
        cache: nil,
        ttl: DEFAULT_TTL,
        max_attempts: DEFAULT_ATTEMPTS,
        sleeper: nil,
        http: nil,
        schedule_retry: true
      )
        @base_url = https_base_url(base_url)
        @token = token.presence
        @cache = cache
        @ttl = ttl
        @max_attempts = [ max_attempts.to_i, 1 ].max
        @sleeper = sleeper
        @http = http || Http.new
        @schedule_retry = schedule_retry
      end

      def check_eligibility(request)
        cached = read_cache(request)
        return cached if cached

        result = with_retries(request)
        write_cache(request, result)
        schedule_retry(request) if result.pending?
        result
      end

      def call(request)
        check_eligibility(request)
      end

      def coverage_for(patient_dfn:, coverage_type:)
        response = @http.get(coverage_url(patient_dfn, coverage_type), headers: fhir_headers)
        coverage_entries(response)
      rescue *RETRYABLE_NETWORK_ERRORS
        raise ClientError, "Enrollment coverage request failed"
      end

      private

      def https_base_url(base_url)
        value = base_url.to_s.strip.sub(%r{/+\z}, "")
        raise ArgumentError, "base_url is required" if value.empty?

        uri = URI.parse(value)
        raise ArgumentError, "base_url must be an https URL" unless https_uri?(uri)

        value
      rescue URI::InvalidURIError
        raise ArgumentError, "base_url must be an https URL"
      end

      def https_uri?(uri)
        return false unless uri.is_a?(URI::HTTPS)
        return false if uri.host.blank? || uri.userinfo.present?
        return false if uri.query.present? || uri.fragment.present?

        true
      end

      def with_retries(request)
        last_error = nil

        @max_attempts.times do |attempt|
          result = post_once(request)
          return result unless result.nil?

          last_error = nil
          pause(attempt)
        rescue *RETRYABLE_NETWORK_ERRORS => error
          last_error = error
          pause(attempt)
        end

        log_unavailable(last_error)
        pending_result(request)
      end

      def post_once(request)
        response = @http.post(eligibility_url, body: fhir_body(request), headers: fhir_headers)
        interpret_eligibility(request, response)
      end

      def interpret_eligibility(request, response)
        code = response.code.to_i
        return if retryable_status?(code)
        return error_result(request) unless success_status?(code)

        eligibility_from_body(request, response.body)
      end

      def retryable_status?(code)
        code == 429 || code.between?(500, 599)
      end

      def success_status?(code)
        code.between?(200, 299)
      end

      # Nil means "not an answer". Callers turn that into error, never
      # enrolled or not_enrolled.
      def eligibility_from_body(request, body)
        payload = json_object(body)
        status = payload && answered_status(payload, request)
        return error_result(request) unless status

        result_for(request, status, benefit_period(payload))
      end

      def answered_status(payload, request)
        return unless payload["resourceType"] == "CoverageEligibilityResponse"
        return unless patient_matches?(payload, request)

        status_from_outcome(payload)
      end

      def patient_matches?(payload, request)
        reference = payload.dig("patient", "reference")
        reference.blank? || reference == "Patient/#{request.patient_dfn}"
      end

      def status_from_outcome(payload)
        case payload["outcome"]
        when "complete" then inforce_status(payload["insurance"])
        when "queued" then "pending"
        end
      end

      def inforce_status(insurance)
        return unless insurance.is_a?(Array) && insurance.any?

        flags = insurance.map { |item| item.is_a?(Hash) ? boolean_inforce(item["inforce"]) : nil }
        return "enrolled" if flags.any?(true)
        return "not_enrolled" if flags.all?(false)

        nil
      end

      # JSON true/false only. A string or a missing flag is not an answer.
      def boolean_inforce(value)
        value if value == true || value == false
      end

      def benefit_period(payload)
        period = payload.dig("insurance", 0, "benefitPeriod")
        return {} unless period.is_a?(Hash)

        { start: iso_date(period["start"]), end: iso_date(period["end"]) }
      end

      def iso_date(value)
        return if value.blank?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def result_for(request, status, period = {})
        CoverageEligibilityResponse.new(
          patient_dfn: request.patient_dfn,
          coverage_type: request.coverage_type,
          status: status,
          request_id: request.id,
          start_date: period[:start],
          end_date: period[:end]
        )
      end

      def error_result(request)
        result_for(request, "error")
      end

      def pending_result(request)
        result_for(request, "pending")
      end

      def pause(attempt)
        return if attempt >= @max_attempts - 1

        seconds = BACKOFF_SECONDS * (2**attempt)
        @sleeper ? @sleeper.call(seconds) : sleep(seconds)
      end

      def log_unavailable(error)
        reason = error ? error.class.name : "transient HTTP status"
        Rails.logger.error("Enrollment eligibility check unavailable after retries: #{reason}")
      end

      def schedule_retry(request)
        return unless @schedule_retry

        EnrollmentEligibilityRetryJob.perform_later(**retry_arguments(request))
      end

      def retry_arguments(request)
        {
          patient_dfn: request.patient_dfn,
          coverage_type: request.coverage_type,
          service_date: request.service_date&.iso8601,
          provider_npi: request.provider_npi,
          purpose: request.purpose,
          base_url: @base_url
        }
      end

      def read_cache(request)
        return unless @cache

        stored = @cache.read(cache_key(request))
        return unless stored.is_a?(Hash)

        CoverageEligibilityResponse.new(stored.symbolize_keys)
      end

      def write_cache(request, result)
        return unless @cache
        return unless result.enrolled? || result.not_enrolled?

        @cache.write(cache_key(request), cache_payload(result), expires_in: @ttl)
      end

      def cache_key(request)
        "enrollment-eligibility/#{Digest::SHA256.hexdigest(cache_material(request))}"
      end

      def cache_material(request)
        [
          request.patient_dfn.to_s,
          request.coverage_type.to_s,
          request.service_date&.iso8601.to_s,
          request.purpose.to_s,
          request.provider_npi.to_s
        ].join("\x1f")
      end

      def cache_payload(result)
        {
          "patient_dfn" => result.patient_dfn,
          "coverage_type" => result.coverage_type,
          "status" => result.status,
          "request_id" => result.request_id,
          "start_date" => result.start_date&.iso8601,
          "end_date" => result.end_date&.iso8601
        }
      end

      def coverage_entries(response)
        code = response.code.to_i
        raise ClientError, "Enrollment coverage request failed with HTTP #{code}" unless success_status?(code)

        list_coverages(json_object(response.body))
      end

      def list_coverages(payload)
        raise ClientError, "Enrollment coverage response was malformed" unless payload.is_a?(Hash)
        raise ClientError, "Enrollment coverage response was malformed" unless payload["resourceType"] == "Bundle"

        entries = payload["entry"]
        return [] if entries.blank? && !positive_total?(payload)
        raise ClientError, "Enrollment coverage response was malformed" unless entries.is_a?(Array)

        resources = entries.filter_map { |entry| coverage_resource(entry) }
        raise ClientError, "Enrollment coverage response was malformed" if resources.empty? && positive_total?(payload)

        resources
      end

      def positive_total?(payload)
        payload["total"].is_a?(Integer) && payload["total"].positive?
      end

      def coverage_resource(entry)
        resource = entry.is_a?(Hash) ? entry["resource"] : nil
        resource if resource.is_a?(Hash) && resource["resourceType"] == "Coverage"
      end

      def coverage_url(patient_dfn, coverage_type)
        query = URI.encode_www_form(
          "beneficiary" => "Patient/#{patient_dfn}",
          "status" => "active",
          "type" => coverage_type.to_s
        )
        "#{@base_url}/Coverage?#{query}"
      end

      def eligibility_url
        "#{@base_url}/CoverageEligibilityRequest"
      end

      def fhir_body(request)
        JSON.generate(request.to_fhir)
      end

      def fhir_headers
        headers = {
          "Accept" => FHIR_MEDIA_TYPE,
          "Content-Type" => FHIR_MEDIA_TYPE
        }
        headers["Authorization"] = "Bearer #{@token}" if @token
        headers
      end

      def json_object(body)
        parsed = JSON.parse(body.to_s)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
