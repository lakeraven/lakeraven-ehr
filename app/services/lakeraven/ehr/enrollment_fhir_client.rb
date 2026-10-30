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
    # Eligibility is fail-closed. A response is enrolled or not_enrolled only
    # when it is an active, complete CoverageEligibilityResponse for this
    # patient and this request, and only from insurance items for the
    # requested coverage type. The patient reference must be exactly
    # Patient/<dfn>. servicedDate, when present, must be this request's
    # service date. request.reference, when present, must name this
    # CoverageEligibilityRequest. A non-empty error list is never terminal:
    # transient AAA codes are pending and a retry is enqueued; any other
    # code is an error. A coverage type matches a trimmed display, or the
    # reference id, exactly and without case. When both are present they
    # must agree. A benefit period, when present, must be a FHIR date or
    # dateTime and must cover the service date. A dateTime is compared by
    # its calendar date. A partial start is the first day of that year or
    # month, and a partial end is the last day. A date outside that window
    # is not_enrolled. A period that starts after it ends, or a period when
    # the request has no service date, is an error. Malformed data is an
    # error. check_eligibility does not raise: transport errors are retried,
    # then the check is pending and a retry job is enqueued. If that enqueue
    # raises, the check stays pending and a fixed line is logged.
    #
    # Terminal answers are cached under a digest of the base URL and the
    # request identity. The raw patient identifier is not the key and is not
    # stored. A hit requires a terminal status, the identity digest, the
    # coverage type, and the service date when the request has one. It is
    # returned with the current request id. Pending and error results are
    # not cached.
    #
    # coverage_for returns active Coverage resources whose type coding code
    # or type text matches the requested type exactly, without case, and
    # whose period covers today. The bundle must be a searchset. A next
    # link may be relative to the base URL and must stay on that origin.
    #
    # The bearer token defaults from LAKERAVEN_ENROLLMENT_FHIR_TOKEN.
    # EnrollmentEligibilityRetryJob reads that same variable; it is not put
    # on the job. Logs and errors omit the patient identifier, the bearer
    # token, and the request body.
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
      MAX_COVERAGE_PAGES = 10
      TERMINAL_STATUSES = %w[enrolled not_enrolled].freeze
      ACTIVE_COVERAGE_STATUS = "active"
      OUTCOME_ERROR_SEVERITIES = %w[error fatal].freeze
      SEARCHSET_BUNDLE = "searchset"
      RETRY_ENQUEUE_FAILED = "Enrollment eligibility retry could not be enqueued"
      # FHIR R4 date: YYYY, YYYY-MM, or YYYY-MM-DD. Year 0000 is not a year.
      FHIR_DATE_FORMAT = /\A(?<year>\d{4})(?:-(?<month>0[1-9]|1[0-2])(?:-(?<day>0[1-9]|[12]\d|3[01]))?)?\z/
      # Time on a FHIR dateTime. The zone is required and is not applied;
      # callers keep the calendar date in the date portion.
      FHIR_TIME_FORMAT = /
        \AT
        (?:[01]\d|2[0-3]):[0-5]\d:(?:[0-5]\d|60)
        (?:\.\d+)?
        (?:Z|[+-](?:(?:0\d|1[0-3]):[0-5]\d|14:00))
        \z
      /x

      def self.from_environment(base_url: nil)
        url = base_url.presence || ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"].presence
        return if url.blank?

        new(base_url: url, cache: Rails.cache, schedule_retry: false)
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
      rescue StandardError
        error_result(request)
      end

      def call(request)
        check_eligibility(request)
      end

      # Same transport and cache, with retry scheduling turned off. The
      # endpoint stays the one this client was built with.
      def for_retry
        self.class.new(
          base_url: @base_url,
          token: @token,
          cache: @cache,
          ttl: @ttl,
          max_attempts: @max_attempts,
          sleeper: @sleeper,
          http: @http,
          schedule_retry: false
        )
      end

      # A blank URL means the caller did not pin an endpoint. Any other URL
      # must be the one this client was configured with.
      def current_endpoint?(base_url)
        given = base_url.to_s.strip.sub(%r{/+\z}, "")
        given.empty? || given == @base_url
      end

      def coverage_for(patient_dfn:, coverage_type:)
        read_coverages(patient_dfn, coverage_type)
      rescue ClientError
        raise
      rescue StandardError
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
        body = fhir_body(request)
        last_error = nil

        @max_attempts.times do |attempt|
          result, error = post_attempt(request, body)
          return result if result

          last_error = error
          pause(attempt)
        end

        log_unavailable(last_error)
        pending_result(request)
      end

      # A transport failure is the exception object. Anything else is
      # [status code, body]. Interpretation stays outside this rescue so
      # malformed payloads become error results instead of retries.
      def post_attempt(request, body)
        delivered = post_eligibility(body)
        return [ nil, delivered ] if delivered.is_a?(StandardError)

        code, raw = delivered
        [ interpret_status(request, code, raw), nil ]
      end

      def post_eligibility(body)
        response = @http.post(eligibility_url, body: body, headers: fhir_headers)
        [ response.code.to_i, response.body ]
      rescue StandardError => error
        error
      end

      def interpret_status(request, code, body)
        return if retryable_status?(code)
        return error_result(request) unless success_status?(code)

        eligibility_from_body(request, body)
      end

      def retryable_status?(code)
        code == 429 || code.between?(500, 599)
      end

      def success_status?(code)
        code.between?(200, 299)
      end

      def eligibility_from_body(request, body)
        payload = json_object(body)
        return error_result(request) unless acceptable_response?(payload, request)

        from_errors = listed_error_result(request, payload)
        return from_errors if from_errors

        outcome_result(request, payload)
      end

      def outcome_result(request, payload)
        case payload["outcome"]
        when "complete" then answer_from_insurance(request, payload["insurance"])
        when "queued" then pending_result(request)
        else error_result(request)
        end
      end

      # A non-empty error list is never enrolled or not_enrolled. Transient
      # AAA codes are pending so the retry job can run. Anything else in
      # that list is an error. No list, or an empty one, is not an error by
      # itself.
      def listed_error_result(request, payload)
        return unless payload.key?("error")

        errors = payload["error"]
        return error_result(request) unless errors.is_a?(Array)
        return if errors.empty?

        transient_error_list?(errors) ? pending_result(request) : error_result(request)
      end

      def transient_error_list?(errors)
        codes = eligibility_error_codes(errors)
        codes.any? && codes.all? { |code| transient_error_code?(code) }
      end

      def transient_error_code?(code)
        CoverageEligibilityResponse::TRANSIENT_ERROR_CODES.include?(code)
      end

      def eligibility_error_codes(errors)
        errors.flat_map { |item| codes_on_error_item(item) }
      end

      def codes_on_error_item(item)
        return [] unless item.is_a?(Hash)

        codeable = item["code"]
        return [] unless codeable.is_a?(Hash)

        coding_codes(codeable["coding"])
      end

      def acceptable_response?(payload, request)
        payload.is_a?(Hash) &&
          payload["resourceType"] == "CoverageEligibilityResponse" &&
          payload["status"] == ACTIVE_COVERAGE_STATUS &&
          patient_matches?(payload, request) &&
          serviced_date_matches?(payload, request) &&
          request_reference_matches?(payload, request)
      end

      def patient_matches?(payload, request)
        patient = payload["patient"]
        return false unless patient.is_a?(Hash)

        patient["reference"] == "Patient/#{request.patient_dfn}"
      end

      # Omitted servicedDate does not constrain the answer. A present value
      # must be this request's service date, by calendar date.
      def serviced_date_matches?(payload, request)
        return true unless payload.key?("servicedDate")

        answered = calendar_date(payload["servicedDate"])
        answered.is_a?(Date) && answered == request.service_date
      end

      def calendar_date(value)
        parsed = period_bound(value, :start)
        parsed if parsed.is_a?(Date)
      end

      # Omitted request does not constrain the answer. A present reference
      # must name this CoverageEligibilityRequest.
      def request_reference_matches?(payload, request)
        return true unless payload.key?("request")

        element = payload["request"]
        return false unless element.is_a?(Hash)

        element["reference"] == "CoverageEligibilityRequest/#{request.id}"
      end

      def answer_from_insurance(request, insurance)
        items = insurance_items(insurance)
        return error_result(request) unless items

        matches = items.select { |item| coverage_match?(item, request.coverage_type) }
        return error_result(request) if matches.empty?

        decide_matches(request, matches)
      end

      # A non-Hash entry is malformed. It is not skipped: the response is
      # not a coverage answer.
      def insurance_items(insurance)
        return unless insurance.is_a?(Array)
        return if insurance.empty? || insurance.any? { |item| !item.is_a?(Hash) }

        insurance
      end

      def decide_matches(request, matches)
        outcomes = matches.map { |item| item_outcome(item, request.service_date) }
        return error_result(request) if outcomes.any? { |outcome| outcome[:status].nil? }

        status = outcomes.any? { |outcome| outcome[:status] == "enrolled" } ? "enrolled" : "not_enrolled"
        result_for(request, status, chosen_period(outcomes, status))
      end

      def item_outcome(item, service_date)
        inforce = boolean_inforce(item["inforce"])
        window = benefit_window(item, service_date)
        return { status: nil } if inforce.nil? || window == :malformed

        status = inforce && window != :outside ? "enrolled" : "not_enrolled"
        { status: status, period: window_period(item, window) }
      end

      # JSON true/false only. A string or a missing flag is not an answer.
      def boolean_inforce(value)
        value if value == true || value == false
      end

      # Display is trimmed. The reference id is the final path segment.
      # Both comparisons are exact and case-insensitive. A display and a
      # reference that name different types do not match either type.
      def coverage_match?(item, coverage_type)
        coverage = item["coverage"]
        return false unless coverage.is_a?(Hash)

        needle = coverage_type.to_s.strip
        return false if needle.empty?

        display = normalized_coverage_display(coverage["display"])
        reference_id = coverage_reference_id(coverage["reference"])
        return false if coverage_labels_conflict?(display, reference_id)

        label_matches?(display, needle) || label_matches?(reference_id, needle)
      end

      def normalized_coverage_display(display)
        return if display.nil?

        display.to_s.strip.presence
      end

      def coverage_reference_id(reference)
        return if reference.nil?

        reference.to_s.split("/").reject(&:empty?).last
      end

      def coverage_labels_conflict?(display, reference_id)
        display.present? && reference_id.present? && !display.casecmp?(reference_id)
      end

      def label_matches?(label, needle)
        label.present? && label.casecmp?(needle)
      end

      # :open has no period. :inside covers the service date. :outside does
      # not, which is not_enrolled even when inforce is true. :malformed is
      # an error for the whole response, including a start after the end and
      # a period when the request has no service date.
      def benefit_window(item, service_date)
        period = readable_benefit_period(item)
        return period unless period.is_a?(Hash)

        classify_benefit_window(*period_bounds(period), service_date)
      end

      def period_bounds(period)
        [ period_bound(period["start"], :start), period_bound(period["end"], :end) ]
      end

      def classify_benefit_window(start_on, end_on, service_date)
        return :malformed unless valid_benefit_bounds?(start_on, end_on, service_date)
        return :open if start_on.nil? && end_on.nil?
        return :outside if outside_window?(service_date, start_on, end_on)

        :inside
      end

      def valid_benefit_bounds?(start_on, end_on, service_date)
        return false if invalid_bound?(start_on) || invalid_bound?(end_on)
        return false if inverted_period?(start_on, end_on)
        return false if dated_period?(start_on, end_on) && !service_date.is_a?(Date)

        true
      end

      def invalid_bound?(bound)
        bound == :invalid
      end

      def inverted_period?(start_on, end_on)
        start_on.is_a?(Date) && end_on.is_a?(Date) && start_on > end_on
      end

      def dated_period?(start_on, end_on)
        start_on.is_a?(Date) || end_on.is_a?(Date)
      end

      def readable_benefit_period(item)
        return :open unless item.key?("benefitPeriod")

        period = item["benefitPeriod"]
        return :open if period.nil?
        return :malformed unless period.is_a?(Hash)

        period
      end

      # A partial start is the first day of that year or month. A partial
      # end is the last day. A FHIR dateTime keeps the calendar date in the
      # date portion and does not apply the offset. Blank is absent.
      # Anything else is invalid.
      def period_bound(value, bound)
        text = value.to_s.strip
        return if text.empty?

        date_text = fhir_date_text(text)
        return :invalid unless date_text

        match = FHIR_DATE_FORMAT.match(date_text)
        return :invalid unless match && match[:year] != "0000"

        fhir_calendar_date(match, bound)
      rescue ArgumentError, TypeError
        :invalid
      end

      def fhir_date_text(text)
        date_text, separator, time_text = text.partition("T")
        return text if separator.empty?
        return unless fhir_time?(time_text) && full_fhir_date?(date_text)

        date_text
      end

      def fhir_time?(time_text)
        FHIR_TIME_FORMAT.match?("T#{time_text}")
      end

      def full_fhir_date?(text)
        FHIR_DATE_FORMAT.match(text)&.[](:day).present?
      end

      def fhir_calendar_date(match, bound)
        year = match[:year].to_i
        month = match[:month]&.to_i
        day = match[:day]&.to_i
        return Date.new(year, month, day) if day
        return month_bound(year, month, bound) if month

        year_bound(year, bound)
      end

      def month_bound(year, month, bound)
        day = bound == :end ? -1 : 1
        Date.new(year, month, day)
      end

      def year_bound(year, bound)
        bound == :end ? Date.new(year, 12, 31) : Date.new(year, 1, 1)
      end

      def outside_window?(service_date, start_on, end_on)
        (start_on.is_a?(Date) && service_date < start_on) || (end_on.is_a?(Date) && service_date > end_on)
      end

      def window_period(item, window)
        return {} unless window == :inside || window == :outside

        period = item["benefitPeriod"]
        {
          start: period_date(period["start"], :start),
          end: period_date(period["end"], :end)
        }
      end

      def period_date(value, bound)
        parsed = period_bound(value, bound)
        parsed if parsed.is_a?(Date)
      end

      def chosen_period(outcomes, status)
        preferred = outcomes.find { |outcome| outcome[:status] == status && outcome[:period].present? }
        preferred ||= outcomes.find { |outcome| outcome[:period].present? }
        preferred ? preferred[:period] : {}
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
        reason = error.is_a?(Exception) ? error.class.name : "transient HTTP status"
        Rails.logger.error("Enrollment eligibility check unavailable after retries: #{reason}")
      end

      def schedule_retry(request)
        return unless @schedule_retry

        EnrollmentEligibilityRetryJob.perform_later(**retry_arguments(request))
      rescue StandardError
        Rails.logger.error(RETRY_ENQUEUE_FAILED)
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

        payload = cache_hash(@cache.read(cache_key(request)))
        return unless payload && cache_payload_valid?(payload, request)

        result_for(request, payload["status"].to_s, cached_period(payload))
      rescue StandardError
        nil
      end

      def cache_payload_valid?(payload, request)
        terminal_cache_status?(payload) &&
          cache_identity_matches?(payload, request) &&
          cache_coverage_type_matches?(payload, request) &&
          cache_service_date_matches?(payload, request) &&
          !field_mismatch?(payload, "patient_dfn", request.patient_dfn)
      end

      def terminal_cache_status?(payload)
        TERMINAL_STATUSES.include?(payload["status"].to_s)
      end

      def cache_identity_matches?(payload, request)
        digest = payload["request_identity_digest"]
        digest.present? && digest.to_s == request_identity_digest(request)
      end

      def cache_coverage_type_matches?(payload, request)
        payload.key?("coverage_type") && payload["coverage_type"].to_s == request.coverage_type.to_s
      end

      def cache_service_date_matches?(payload, request)
        expected = request.service_date&.iso8601
        return stored_service_date_blank?(payload) if expected.nil?

        payload["service_date"].to_s == expected
      end

      def stored_service_date_blank?(payload)
        !payload.key?("service_date") || payload["service_date"].blank?
      end

      def field_mismatch?(payload, key, expected)
        payload.key?(key) && payload[key].to_s != expected.to_s
      end

      def cached_period(payload)
        { start: payload["start_date"], end: payload["end_date"] }
      end

      def write_cache(request, result)
        return unless @cache
        return unless result.enrolled? || result.not_enrolled?

        @cache.write(cache_key(request), cache_payload(request, result), expires_in: @ttl)
      rescue StandardError
        nil
      end

      def cache_key(request)
        material = [ @base_url, request_identity(request) ].join("\x1f")
        "enrollment-eligibility/#{Digest::SHA256.hexdigest(material)}"
      end

      def request_identity_digest(request)
        Digest::SHA256.hexdigest(request_identity(request))
      end

      def request_identity(request)
        [
          request.patient_dfn.to_s,
          request.coverage_type.to_s,
          request.service_date&.iso8601.to_s,
          request.purpose.to_s,
          request.provider_npi.to_s
        ].join("\x1f")
      end

      # The patient identifier is an input to the digest only. It is not
      # stored, so a cache read cannot leak it and a forged entry that names
      # a different patient is ignored.
      def cache_payload(request, result)
        {
          "status" => result.status,
          "coverage_type" => result.coverage_type,
          "service_date" => request.service_date&.iso8601,
          "request_identity_digest" => request_identity_digest(request),
          "start_date" => result.start_date&.iso8601,
          "end_date" => result.end_date&.iso8601
        }
      end

      def cache_hash(stored)
        return unless stored.is_a?(Hash)

        stored.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value }
      end

      def read_coverages(patient_dfn, coverage_type)
        url = coverage_url(patient_dfn, coverage_type)
        found = []

        MAX_COVERAGE_PAGES.times do
          payload = fetch_bundle(url)
          found.concat(coverages_from_bundle(payload, patient_dfn, coverage_type))
          url = next_page_url(payload)
          return found unless url
        end

        raise ClientError, "Enrollment coverage search exceeded the page limit"
      end

      def fetch_bundle(url)
        response = @http.get(url, headers: fhir_headers)
        code = response.code.to_i
        raise ClientError, "Enrollment coverage request failed with HTTP #{code}" unless success_status?(code)

        payload = json_object(response.body)
        raise ClientError, "Enrollment coverage response was malformed" unless bundle?(payload)

        payload
      end

      def bundle?(payload)
        payload.is_a?(Hash) &&
          payload["resourceType"] == "Bundle" &&
          payload["type"] == SEARCHSET_BUNDLE
      end

      def coverages_from_bundle(payload, patient_dfn, coverage_type)
        raise ClientError, "Enrollment coverage search returned an error" if outcome_error?(payload)

        entries = payload["entry"]
        return [] if entries.blank? && !positive_total?(payload)
        raise ClientError, "Enrollment coverage response was malformed" unless entries.is_a?(Array)

        resources = entries.filter_map { |entry| coverage_resource(entry) }
        raise ClientError, "Enrollment coverage response was malformed" if resources.empty? && positive_total?(payload)

        resources.each { |resource| verify_beneficiary!(resource, patient_dfn) }
        resources.select { |resource| current_coverage?(resource, coverage_type) }
      end

      def current_coverage?(resource, coverage_type)
        resource["status"] == ACTIVE_COVERAGE_STATUS &&
          coverage_type_matches?(resource, coverage_type) &&
          coverage_period_current?(resource)
      end

      # type.coding code or type.text, the whole value, without case.
      def coverage_type_matches?(resource, coverage_type)
        needle = coverage_type.to_s.strip
        return false if needle.empty?

        coverage_type_labels(resource).any? { |label| label_matches?(label, needle) }
      end

      def coverage_type_labels(resource)
        type = resource["type"]
        return [] unless type.is_a?(Hash)

        coding_codes(type["coding"]) + [ normalized_coverage_display(type["text"]) ].compact
      end

      def coding_codes(coding)
        return [] unless coding.is_a?(Array)

        coding.filter_map { |entry| coding_code(entry) }
      end

      def coding_code(entry)
        return unless entry.is_a?(Hash)
        return if entry["code"].nil?

        entry["code"].to_s.strip.presence
      end

      # A missing period does not exclude the resource. A start after today,
      # an end before today, or an unreadable period does.
      def coverage_period_current?(resource, today = Date.current)
        period = resource["period"]
        return true if period.nil?
        return false unless period.is_a?(Hash)

        start_on, end_on = period_bounds(period)
        return false unless valid_coverage_bounds?(start_on, end_on)

        covers_day?(today, start_on, end_on)
      end

      def valid_coverage_bounds?(start_on, end_on)
        return false if invalid_bound?(start_on) || invalid_bound?(end_on)
        return false if inverted_period?(start_on, end_on)

        true
      end

      def covers_day?(day, start_on, end_on)
        return false if start_on.is_a?(Date) && day < start_on
        return false if end_on.is_a?(Date) && day > end_on

        true
      end

      def outcome_error?(payload)
        entries = payload["entry"]
        return false unless entries.is_a?(Array)

        entries.any? { |entry| operation_outcome_error?(entry) }
      end

      def operation_outcome_error?(entry)
        resource = entry.is_a?(Hash) ? entry["resource"] : nil
        return false unless resource.is_a?(Hash)
        return false unless resource["resourceType"] == "OperationOutcome"

        issues = resource["issue"]
        return false unless issues.is_a?(Array)

        issues.any? { |issue| issue.is_a?(Hash) && OUTCOME_ERROR_SEVERITIES.include?(issue["severity"]) }
      end

      def positive_total?(payload)
        payload["total"].is_a?(Integer) && payload["total"].positive?
      end

      def coverage_resource(entry)
        resource = entry.is_a?(Hash) ? entry["resource"] : nil
        resource if resource.is_a?(Hash) && resource["resourceType"] == "Coverage"
      end

      def verify_beneficiary!(resource, patient_dfn)
        return if beneficiary_matches?(resource, patient_dfn)

        raise ClientError, "Enrollment coverage beneficiary did not match the requested patient"
      end

      def beneficiary_matches?(resource, patient_dfn)
        beneficiary = resource["beneficiary"]
        return false unless beneficiary.is_a?(Hash)

        beneficiary["reference"] == "Patient/#{patient_dfn}"
      end

      def next_page_url(payload)
        raw = link_url(payload, "next")
        return if raw.nil?

        url = absolute_page_url(raw)
        raise ClientError, "Enrollment coverage page is not on the enrollment host" unless url && same_origin?(url)

        url
      end

      # A path or bare relative link is resolved against the base URL.
      # An absolute link is left unchanged so same_origin? can reject it.
      def absolute_page_url(url)
        text = url.to_s.strip
        return if text.empty?

        parsed = URI.parse(text)
        return text if parsed.scheme.present? || parsed.host.present?

        URI.join("#{@base_url}/", text).to_s
      rescue URI::InvalidURIError
        nil
      end

      def link_url(payload, relation)
        links = payload["link"]
        return unless links.is_a?(Array)

        link = links.find { |item| item.is_a?(Hash) && item["relation"] == relation }
        link && link["url"].presence
      end

      def same_origin?(url)
        uri = URI.parse(url.to_s)
        base = URI.parse(@base_url)
        uri.is_a?(URI::HTTPS) && uri.host.to_s.casecmp?(base.host.to_s) && uri.port == base.port
      rescue URI::InvalidURIError
        false
      end

      def coverage_url(patient_dfn, coverage_type)
        query = URI.encode_www_form(
          "beneficiary" => "Patient/#{patient_dfn}",
          "status" => ACTIVE_COVERAGE_STATUS,
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
      rescue JSON::ParserError, TypeError
        nil
      end
    end
  end
end
