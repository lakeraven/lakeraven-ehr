# frozen_string_literal: true

module Lakeraven
  module EHR
    # Server-rendered allergy entry from the chart (#644).
    #
    # Same credential as the chart and the screening surface: a SMART token,
    # its scopes, and a clinician DUZ, plus the session's deliberate patient
    # context. The originator filed with the allergy is that DUZ. A request
    # parameter cannot name someone else.
    #
    # An allergy write is an RPC. It cannot join the audit transaction, so a
    # failed audit cannot undo it. The action proves the audit insert works
    # and rolls that proof back before calling the gateway. The row that
    # remains is the one AuditableClinicalAccess writes after the response
    # status is known. If the proof insert fails, the gateway is not called.
    # If the RPC succeeded and that later row fails, the response says the
    # write is already in RPMS and must not be entered again. An unknown
    # RPC outcome says the chart must be checked; a nothing-written refusal
    # keeps the shared not-completed response.
    class AllergiesController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext
      include AuditLogProbe

      ALLERGY_RESOURCE = "AllergyIntolerance"
      SCALAR_FIELDS = %w[
        agent agent_pointer type nature originated_at
        observed_or_historical reaction_date severity
      ].freeze
      SYMPTOM_FIELDS = %w[ien text date].freeze
      # A backend error symbol is safe to keep. Free text is not.
      SAFE_GATEWAY_ERROR = /\A[a-z][a-z0-9_]*\z/
      INDEX_KEY = /\A-?\d+\z/
      # Proof the chart was not changed. Any other failure, including
      # :unavailable, :malformed_reply, :empty_reply, nil, or a symbol
      # this list does not name, is an unknown outcome.
      NOTHING_WRITTEN = %i[
        duplicate active_allergies locked invalid_value missing_fields
        clinician_required invalid_dfn frame_too_long
      ].freeze

      rate_limit only: %i[new create no_known_allergies]

      before_action :authenticate_smart_token!
      before_action :authorize_allergy_scope!
      # Forgery protection runs before authentication and raises. A browser
      # with no credential gets the same 401 as any other anonymous write;
      # a signed-in browser keeps the cross-site refusal.
      rescue_from ActionController::InvalidAuthenticityToken, with: :reject_forged_allergy_write
      before_action :require_clinician_credential!, only: %i[create no_known_allergies]
      before_action :load_patient
      before_action :enforce_token_patient_context!
      before_action :enforce_patient_context!

      # The entry form. A Find button resubmits it here (GET, nothing filed)
      # with an allergen or symptom search, so what was already entered is
      # shown again beside the matches RPMS's own search gives.
      def new
        @form_values = form_values
        @allergen_matches = allergen_matches
        @symptom_matches = symptom_matches
      end

      def create
        return if audit_unwritable?

        @form_values = form_values
        @allergy = parse_allergy
        if @allergy && allergen_confirmed? && allergy_recorded?
          redirect_to patient_chart_path(@dfn), notice: "Allergy recorded."
        else
          render_allergy_not_saved
        end
      end

      def no_known_allergies
        return if audit_unwritable?

        if nka_recorded?
          redirect_to patient_chart_path(@dfn), notice: "No known allergies recorded."
        else
          render :no_known_allergies, status: :unprocessable_entity
        end
      end

      private

      helper_method :form_value, :comment_value
      helper_method :allergy_failure_heading, :allergy_failure_detail
      helper_method :nka_failure_heading, :nka_failure_detail

      def authorize_allergy_scope!
        return true if allergy_scope_permitted?

        verb = request.get? ? "read" : "record"
        render_forbidden("Insufficient scope to #{verb} #{ALLERGY_RESOURCE}")
        false
      end

      # Reading takes the token's AllergyIntolerance read. Recording takes that
      # read and the "allergy.record" capability, from the keys RPMS reported
      # at sign-on (PROVIDER or BGOZ CAC, never BGOZ VIEW ONLY): sign-on mints
      # no AllergyIntolerance write scope (S-TRI-04.2). The entry form is
      # offered on the same terms.
      def allergy_scope_permitted?
        can_read?(ALLERGY_RESOURCE) && capability?("allergy.record")
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      def require_clinician_credential!
        return true if current_duz.present?

        render_forbidden("Recording an allergy requires a clinician sign-on")
        false
      end

      def load_patient
        @dfn = params[:dfn]
      end

      def reject_forged_allergy_write
        if session[:smart_token].present?
          head :unprocessable_entity
        else
          render_unauthorized("No Bearer token provided")
        end
      end

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      # The proof row is rolled back. A raised insert means the log cannot
      # record this access, so the RPC must not run.
      def audit_unwritable?
        return false if audit_log_writable?

        render_unrecorded_access_denial
        true
      end

      # Remember the class, then let the concern refuse the access. The
      # message is not logged: it can carry the broker's own text.
      def record_audit_event!(detached: false)
        super(detached: detached)
      rescue StandardError => error
        @rpms_audit_error = error
        raise
      end

      # The shared refusal is right when the chart was not changed: the RPC
      # never ran, or it refused with a NOTHING_WRITTEN symbol. A committed
      # write must not be entered again. An unknown outcome may already be
      # on the chart.
      def render_unrecorded_access_denial
        case write_outcome
        when :written
          log_unaudited_rpms_write
          render plain: unaudited_rpms_message, status: :service_unavailable
        when :unknown
          log_unaudited_unknown_outcome
          render plain: unaudited_unknown_message, status: :service_unavailable
        else
          super
        end
      end

      def log_unaudited_rpms_write
        Rails.logger.error(
          "ERROR [allergy] #{action_name} recorded in RPMS but this access could not be audited: " \
          "#{@rpms_audit_error&.class}"
        )
      end

      def unaudited_rpms_message
        subject = @rpms_write == :nka ? "No known allergies were" : "This allergy was"
        "Service Unavailable: #{subject} recorded in RPMS, but this access could not be audited. " \
          "It must not be entered again."
      end

      # Class only. The insert error's message can carry broker text.
      def log_unaudited_unknown_outcome
        Rails.logger.error(
          "ERROR [allergy] #{action_name} outcome unknown; this access could not be audited: " \
          "#{@rpms_audit_error&.class}"
        )
      end

      def unaudited_unknown_message
        subject = action_name == "no_known_allergies" ? "No known allergies" : "This allergy"
        "Service Unavailable: #{subject} may have been recorded in RPMS. " \
          "The outcome is unknown, and this access could not be audited. " \
          "Check the chart before entering it again."
      end

      # An unknown write is a serious failure even though the page is a 422:
      # the chart may have changed. A nothing-written refusal stays a "4"
      # and names its symbol. Success is left to the concern.
      def audit_outcome
        return "8" if write_outcome == :unknown

        super
      end

      def audit_outcome_desc
        [ super, write_outcome_note ].compact.join("; ").presence
      end

      # written, nothing written (a NOTHING_WRITTEN symbol), or unknown.
      def write_outcome
        return :written if @rpms_write
        return unless @gateway_failure

        outcome_unknown? ? :unknown : :nothing_written
      end

      def write_outcome_note
        case write_outcome
        when :unknown
          [ "write outcome unknown", @allergy_error ].compact.join(": ")
        when :nothing_written
          "refused: #{@allergy_error}"
        end
      end

      def audit_probe_log_tag = "allergy"
      def audit_probe_dfn = @dfn

      def allergy_recorded?
        result = AllergyIntoleranceGateway.add(@dfn, @allergy, clinician_duz: current_duz)
        note_gateway_result(:allergy, result)
      end

      def nka_recorded?
        result = AllergyIntoleranceGateway.record_no_known_allergies(@dfn)
        note_gateway_result(:nka, result)
      end

      def note_gateway_result(kind, result)
        if gateway_succeeded?(result)
          @rpms_write = kind
          true
        else
          @gateway_failure = true
          @allergy_error = safe_gateway_error(result)
          false
        end
      end

      def gateway_succeeded?(result)
        result.is_a?(Hash) && result[:success] == true
      end

      # Only the symbol. The backend's message text is never kept.
      def safe_gateway_error(result)
        error = result[:error] if result.is_a?(Hash)
        error if error.is_a?(Symbol) && error.name.match?(SAFE_GATEWAY_ERROR)
      end

      def render_allergy_not_saved
        @allergy ||= {}
        @allergen_matches ||= []
        @symptom_matches ||= []
        @allergy_not_saved = true
        render :new, status: :unprocessable_entity
      end

      # The only read of the submitted allergy. Scalars, symptom rows, and
      # comments are strings in the shapes the form posts; anything else is
      # refused before the gateway runs. An empty scalar is absence. A fully
      # blank symptom row and a blank comment are the empty controls on the
      # shipped form, and are left out. originator is not a field: the
      # gateway files the clinician DUZ, so a posted one is discarded.
      def parse_allergy
        raw = rpms_allergy_input
        return unless raw

        parsed = {}
        raw.each do |key, value|
          piece = strict_field(key.to_s, value)
          return unless piece

          parsed.merge!(piece)
        end
        with_lists(parsed)
      end

      # The submitted allergy with the form's own values (a search match,
      # date pickers, a catalog symptom) turned into RPMS's (AllergyEntryForm).
      # A refused form value is kept as the reason; nothing reaches RPMS.
      def rpms_allergy_input
        raw = allergy_input
        return unless raw

        form = AllergyEntryForm.to_rpms(raw, now: SiteTime.now)
        @allergy_error = form.error
        @chosen_agent = form.chosen_agent
        form.allergy
      end

      # An allergen chosen on the form is filed only if RPMS's own search for
      # it still offers that agent and pointer (AllergenGateway.offers?), so
      # what RPMS receives is a pair its search gave. A search that does not
      # answer files nothing.
      def allergen_confirmed?
        return true unless @chosen_agent

        offered = AllergenGateway.offers?(@chosen_agent[:agent], @chosen_agent[:agent_pointer])
        @allergy_error = :allergen_not_offered unless offered
        offered
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.warn("[allergy] allergen check failed: #{e.class}")
        @allergy_error = :allergen_search_failed
        false
      end

      # What the form shows: the values it last posted (after a Find, or a
      # refusal), with the entry time defaulting to the site's now.
      def form_values
        raw = params[:allergy]
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        values = raw.is_a?(Hash) ? raw.select { |_key, value| value.is_a?(String) } : {}
        values = values.to_h { |key, value| [ key.to_s, value ] }
        values["originated_on"] = site_now_for_picker if values["originated_on"].blank?
        values
      end

      def allergen_matches
        text = params[:allergen_search].to_s.strip
        return [] if text.empty?

        AllergenGateway.search(text).uniq { |match| allergen_choice(match) }
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.warn("[allergy] allergen search failed: #{e.class}")
        @allergen_search_failed = true
        []
      end

      def symptom_matches
        text = params[:symptom_search].to_s.strip
        return [] if text.empty?

        SymptomGateway.starting_with(text)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.warn("[allergy] symptom search failed: #{e.class}")
        @symptom_search_failed = true
        []
      end

      helper_method :allergen_choice, :allergen_label, :chosen_text
      helper_method :allergen_empty_text, :symptom_empty_text
      helper_method :site_now_for_picker, :site_today_for_picker

      def allergen_choice(match) = "#{match[:agent_pointer]}^#{match[:agent]}"

      # The agent, the synonym that found it, and the file it is from.
      def allergen_label(match)
        found_as = " (found as #{match[:synonym]})" if match[:synonym]
        from = " - #{match[:source_name]}" if match[:source_name]
        "#{match[:agent]}#{found_as}#{from}"
      end

      # "Allergen chosen: STRAWBERRIES." for a choice kept across a Find.
      def chosen_text(choice, what)
        name = choice.to_s.split("^", 2).last
        "#{what} chosen: #{name}." if name.present?
      end

      def allergen_empty_text
        return "RPMS's allergen search did not answer. Try again." if @allergen_search_failed
        return if params[:allergen_search].blank?

        "No allergen starts with #{params[:allergen_search].to_s.strip.upcase}."
      end

      def symptom_empty_text
        return "RPMS's symptom search did not answer. Try again." if @symptom_search_failed
        return if params[:symptom_search].blank?

        "No symptom starts with #{params[:symptom_search].to_s.strip.upcase}."
      end

      def site_now_for_picker = SiteTime.now.strftime("%Y-%m-%dT%H:%M")
      def site_today_for_picker = SiteTime.today.iso8601

      # Rails removes nils from parameter arrays before the action, so a nil
      # comment would vanish and the rest would be filed. The raw JSON body
      # still has it.
      def allergy_input
        raw = json_request? ? json_allergy : params[:allergy]
        return raw if raw.is_a?(Hash)
        return raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

        nil
      end

      def json_request?
        request.media_type == "application/json"
      end

      def json_allergy
        body = request.raw_post
        return if body.blank?

        data = JSON.parse(body)
        data["allergy"] if data.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def strict_field(key, value)
        case key
        when "originator" then {}
        when "symptoms" then list_field("symptoms", parsed_symptoms(value))
        when "comments" then list_field("comments", parsed_comments(value))
        else scalar_field(key, value)
        end
      end

      # An empty string is a blank control: allowed, and not filed.
      def scalar_field(key, value)
        return unless SCALAR_FIELDS.include?(key)
        return unless value.is_a?(String)

        value.empty? ? {} : { key => value }
      end

      def list_field(key, entries)
        { key => entries } unless entries.nil?
      end

      def parsed_symptoms(value)
        rows = list_entries(value)
        return unless rows

        built = rows.map { |row| symptom_fields(row) }
        return if built.any?(&:nil?)

        built.reject { |row| blank_symptom?(row) }
      end

      def parsed_comments(value)
        lines = list_entries(value)
        return unless lines
        return unless lines.all? { |line| line.is_a?(String) }

        lines.reject(&:blank?)
      end

      def list_entries(value)
        value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
        case value
        when Array then value
        when Hash then indexed_entries(value)
        end
      end

      def indexed_entries(value)
        pairs = value.to_a
        return unless pairs.all? { |key, _entry| index_key?(key) }

        # Decimal, not octal: "08" is 8 and "010" sorts after "9".
        pairs.sort_by { |key, _entry| Integer(key.to_s, 10) }.map(&:last)
      end

      def symptom_fields(row)
        row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
        return unless row.is_a?(Hash)
        return unless row.all? { |key, field| symptom_field?(key, field) }

        row.each_with_object({}) { |(key, field), fields| fields[key.to_s] = field }
      end

      def symptom_field?(key, field)
        SYMPTOM_FIELDS.include?(key.to_s) && field.is_a?(String)
      end

      def blank_symptom?(row)
        row.values.none? { |field| field.to_s.strip.present? }
      end

      def with_lists(parsed)
        parsed["symptoms"] ||= []
        parsed["comments"] ||= []
        parsed
      end

      def index_key?(key)
        key.to_s.match?(INDEX_KEY)
      end

      def form_value(key)
        (@form_values || {})[key.to_s]
      end

      def comment_value
        comments = params.dig(:allergy, :comments)
        comments = comments.values if comments.respond_to?(:values) && !comments.is_a?(Array)
        Array(comments).grep(String).first
      end

      def outcome_unknown?
        @gateway_failure && !NOTHING_WRITTEN.include?(@allergy_error)
      end

      def allergy_failure_heading
        return "Outcome unknown" if outcome_unknown?

        case @allergy_error
        when :duplicate then "Already on file"
        when :active_allergies then "Active allergies on file"
        else "This allergy was not saved"
        end
      end

      def allergy_failure_detail
        return outcome_unknown_detail if outcome_unknown?

        case @allergy_error
        when :duplicate then "This allergy is already on file."
        when :active_allergies then "The patient has active allergies on file."
        when :locked then locked_detail
        when :invalid_value, :missing_fields then invalid_or_missing_detail
        when :future_date then "A date or time is later than now at this site."
        when :allergen_not_offered then "RPMS's allergen search no longer offers the chosen allergen. Search again and choose it from the list."
        when :allergen_search_failed then "RPMS's allergen search did not answer, so nothing was saved. Try again."
        else "The allergy was not saved."
        end
      end

      def nka_failure_heading
        return "Outcome unknown" if outcome_unknown?

        case @allergy_error
        when :active_allergies then "Active allergies on file"
        else "Not saved"
        end
      end

      def nka_failure_detail
        return outcome_unknown_detail if outcome_unknown?

        case @allergy_error
        when :active_allergies then "The patient has active allergies on file."
        when :duplicate then "This is already on file."
        when :locked then locked_detail
        when :invalid_value, :missing_fields then invalid_or_missing_detail
        else "This was not saved."
        end
      end

      def outcome_unknown_detail
        "Outcome unknown — check the chart before trying again."
      end

      def locked_detail
        "Another user is editing this patient's allergies, try again shortly."
      end

      def invalid_or_missing_detail
        "A value was invalid or a required value was missing."
      end
    end
  end
end
