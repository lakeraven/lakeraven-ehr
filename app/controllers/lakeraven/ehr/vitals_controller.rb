# frozen_string_literal: true

module Lakeraven
  module EHR
    # The medical assistant takes vitals on one of the patient's open visits
    # (rpms-ux S-TRI-02.1 to .3). RPMS checks each value (BEHOVM VALIDATE) and
    # files them (BEHOVM SAVE), the RPCs VueCentric's vitals entry uses, into
    # V MEASUREMENT (#9000010.01) on the visit, as the connection's signed-on
    # user, at the site's time (SiteTime), not the app host's clock. A value RPMS refuses is shown with RPMS's reason and nothing is
    # filed. The app keeps nothing.
    class VitalsController < WebController
      include VisitCharting

      # The measurement types offered, by their V MEASUREMENT abbreviation,
      # in each type's own units (the units BEHOVM files them in).
      FIELDS = [
        [ "HT", "Height", "in" ], [ "WT", "Weight", "lb" ], [ "BP", "Blood pressure", "mmHg" ],
        [ "PU", "Pulse", "/min" ], [ "RS", "Respirations", "/min" ], [ "TMP", "Temperature", "F" ],
        [ "PA", "Pain (0-10)", "" ], [ "PHQ2", "PHQ-2 score", "" ]
      ].freeze
      VALUE_FORMAT = %r{\A[0-9][0-9./]{0,9}\z}

      helper_method :vital_fields

      def new
        @open_visits = read_open_visits(@dfn)
        @values = {}
      end

      def create
        @values = submitted_values
        @visit_ien = params[:visit_ien].is_a?(String) ? params[:visit_ien] : nil
        @open_visits = read_open_visits(@dfn)
        visit = chosen_open_visit(@dfn, @visit_ien)
        return refuse("Choose one of the patient's open visits.") unless visit
        return refuse("Enter at least one measurement, as a number (a blood pressure as 120/80).") unless measurements

        @rpms_errors = VitalGateway.validate(@dfn, measurements)[:errors]
        return refuse("RPMS refused a value. Correct it and save again; nothing was saved.") if @rpms_errors.any?

        file_vitals(visit)
      end

      private

      def charted_thing = "vitals"

      def vital_fields = FIELDS

      def submitted_values
        raw = params[:vitals]
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        return {} unless raw.is_a?(Hash)

        FIELDS.to_h { |abbreviation, _, _| [ abbreviation, raw[abbreviation].is_a?(String) ? raw[abbreviation].strip : "" ] }
      end

      # The entered values, or nil when none is entered or one is not a number.
      def measurements
        @measurements ||= begin
          entered = FIELDS.reject { |abbreviation, _, _| @values[abbreviation].to_s.empty? }
          if entered.any? && entered.all? { |abbreviation, _, _| @values[abbreviation].match?(VALUE_FORMAT) }
            entered.map { |abbreviation, _, units| { abbreviation: abbreviation, value: @values[abbreviation], units: units } }
          end
        end
      end

      def file_vitals(visit)
        visit_string = ::RpmsRpc::Encounter.visit_string(visit[:location_ien], visit[:datetime], visit[:service_category],
                                                         visit_ien: canonical_ien(visit[:visit_ien]))
        result = VitalsEntryService.new(dfn: @dfn, visit_string: visit_string, measurements: measurements,
                                        provider_duz: current_duz, taken_at: SiteTime.now, gateway: VitalGateway).save
        @write_outcome = result.success? ? :written : :nothing_written
        return redirect_to(patient_chart_path(@dfn), notice: "Vitals recorded on the visit.") if result.success?

        refuse("RPMS did not record the vitals. Nothing was saved.")
      rescue *UNKNOWN_OUTCOME_ERRORS => error
        Rails.logger.error("[vitals] save raised #{error.class}")
        @write_outcome = :unknown
        refuse("The outcome is unknown. Check the visit's vitals before entering them again.")
      end
    end
  end
end
