# frozen_string_literal: true

module Lakeraven
  module EHR
    # Demo-only UI for charting a walk-in visit end to end — the clickable
    # counterpart of features/encounter/demo_visit.feature. A provider records
    # vitals, a purpose of visit, a signed progress note, and closes the
    # encounter; each beat runs through the SAME service layer the app uses
    # (VitalsEntryService / PovEntryService / ProgressNoteService / Encounter),
    # against injected demo gateways that persist nothing but succeed
    # deterministically. The visit-in-progress is held in the session so the
    # page accumulates what was entered — no real RPMS backend, no PHI.
    #
    # Gated to the SAME dev-only demo bypass as the chart
    # (development? && CHART_DEMO_OPEN=1 && SPIKE_MOCK_RPC=1); it 404s
    # everywhere else, so it can never front a real backend or ship to prod.
    class DemoVisitsController < ActionController::Base
      # Deterministic demo gateways: they mirror the production gateway
      # interfaces the services call, and always report success. Nothing is
      # persisted here — the controller records what the provider entered in
      # the session so the chart can render it back.
      class DemoVitalGateway
        def add(_dfn, _visit_string, _measurements, provider_duz: nil) = { success: true, raw: "1" }
      end

      class DemoPovGateway
        def add(_dfn, _visit_ien, _code, narrative: nil, modifiers: {}) = { success: true, ien: 501, raw: "1^501" }
      end

      class DemoNoteGateway
        def create(_dfn, _visit_ien, _title_ien) = { success: true, ien: 7801, raw: "7801" }
        def update_text(_note_ien, _text) = { success: true, raw: "1" }
      end

      class DemoESignatureGateway
        def validate(_duz, code) = { success: code.to_s.strip.present?, raw: "1" }
        def add(_note_ien, _duz, _code, action: :sign) = { success: true, raw: "1" }
      end

      DEMO_VISIT_IEN = 2090061
      AUTHOR_DUZ = 2843
      NOTE_TITLE_IEN = 8927
      # Prefilled so the presenter can click straight through the flow.
      VITAL_FIELDS = [
        { key: "TMP", label: "Temp",  units: "F",    default: "98.9" },
        { key: "BP",  label: "BP",    units: "mmHg", default: "128/82" },
        { key: "P",   label: "Pulse", units: "/min", default: "74" },
        { key: "R",   label: "Resp",  units: "/min", default: "16" },
        { key: "PO2", label: "SpO2",  units: "%",    default: "98" }
      ].freeze

      before_action :require_demo_mode!
      skip_before_action :verify_authenticity_token
      layout false

      def show
        @patient_name = patient_name(params[:dfn])
        @dfn = params[:dfn]
        @visit = visit_state(@dfn)
      end

      def vitals
        measurements = VITAL_FIELDS.filter_map do |f|
          value = params.dig(:vitals, f[:key]).to_s.strip
          next if value.empty?

          { abbreviation: f[:key], value: value, units: f[:units], label: f[:label] }
        end

        result = Lakeraven::EHR::VitalsEntryService.new(
          dfn: params[:dfn],
          visit_string: "492;#{fm_now};A;#{DEMO_VISIT_IEN}",
          measurements: measurements,
          provider_duz: AUTHOR_DUZ,
          gateway: DemoVitalGateway.new
        ).save

        if result.success?
          update_visit(params[:dfn]) { |v| v["vitals"] = measurements.map { |m| m.transform_keys(&:to_s) } }
          flash[:notice] = "Vitals recorded."
        else
          flash[:alert] = "Vitals failed: #{result.error}"
        end
        redirect_to patient_visit_path(params[:dfn])
      end

      def pov
        result = Lakeraven::EHR::PovEntryService.new(
          dfn: params[:dfn],
          visit_ien: DEMO_VISIT_IEN,
          diagnosis_code: params[:pov_code],
          narrative: params[:pov_narrative],
          gateway: DemoPovGateway.new
        ).save

        if result.success?
          update_visit(params[:dfn]) { |v| v["pov"] = { "code" => params[:pov_code], "narrative" => params[:pov_narrative] } }
          flash[:notice] = "Purpose of visit recorded."
        else
          flash[:alert] = "POV failed: #{result.error}"
        end
        redirect_to patient_visit_path(params[:dfn])
      end

      def note
        service = Lakeraven::EHR::ProgressNoteService.new(
          dfn: params[:dfn],
          visit_ien: DEMO_VISIT_IEN,
          author_duz: AUTHOR_DUZ,
          gateway: DemoNoteGateway.new,
          esignature_gateway: DemoESignatureGateway.new
        )

        created = service.create(title_ien: NOTE_TITLE_IEN, text: params[:note_text])
        unless created.success?
          flash[:alert] = "Note create failed: #{created.error}"
          return redirect_to patient_visit_path(params[:dfn])
        end

        signed = service.sign(note_ien: created.note_ien, signature_code: params[:signature_code])
        update_visit(params[:dfn]) do |v|
          v["note"] = { "text" => params[:note_text], "note_ien" => created.note_ien, "signed" => signed.success? }
        end
        flash[:notice] = signed.success? ? "Note written and signed." : "Note written; signing failed: #{signed.error}"
        redirect_to patient_visit_path(params[:dfn])
      end

      def close
        encounter = Lakeraven::EHR::Encounter.new(
          status: "in-progress", class_code: "AMB", patient_dfn: params[:dfn], ien: DEMO_VISIT_IEN
        )
        if encounter.close(reason_code: params[:close_code], reason_display: params[:close_display])
          update_visit(params[:dfn]) do |v|
            v["status"] = "finished"
            v["close"] = { "code" => params[:close_code], "display" => params[:close_display] }
          end
          flash[:notice] = "Visit closed."
        else
          flash[:alert] = "Visit could not be closed."
        end
        redirect_to patient_visit_path(params[:dfn])
      end

      # Clears the in-progress visit so the demo can be run again from scratch.
      def reset
        session[:demo_visits]&.delete(params[:dfn].to_s)
        redirect_to patient_visit_path(params[:dfn])
      end

      private

      def require_demo_mode!
        demo = Rails.env.development? &&
          ENV["CHART_DEMO_OPEN"] == "1" &&
          ENV["SPIKE_MOCK_RPC"] == "1"
        head :not_found unless demo
      end

      def visit_state(dfn)
        (session[:demo_visits] ||= {})[dfn.to_s] ||= {
          "visit_ien" => DEMO_VISIT_IEN, "status" => "in-progress",
          "vitals" => [], "pov" => nil, "note" => nil
        }
      end

      def update_visit(dfn)
        state = visit_state(dfn)
        yield state
        session[:demo_visits][dfn.to_s] = state
      end

      def patient_name(dfn)
        Lakeraven::EHR::Patient.find_by_dfn(dfn)&.display_name || "Patient ##{dfn}"
      rescue StandardError
        "Patient ##{dfn}"
      end

      # FileMan-ish date/time stamp for the visit string (demo only).
      def fm_now
        t = Time.current
        format("%d%02d%02d.%02d", t.year - 1700, t.month, t.day, t.hour)
      end
    end
  end
end
