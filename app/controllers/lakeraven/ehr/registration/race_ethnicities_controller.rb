# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The patient's races and ethnicities, each with how it was collected
      # (rpms-ux S-REG-20.2 to 20.4), shown on the patient's registration page
      # (race_ethnicities/_section). RPMS has no registration call for them, so
      # the gem files them the way AG's own page 10 does, under AG's edit lock
      # (rpms-ops#1055).
      class RaceEthnicitiesController < PatientSectionController
        EDIT_ACTIONS = %w[edit update].freeze

        # GET /registration/patients/:dfn/race_ethnicity/edit
        def edit
          load_choices
          @entry = RaceEthnicityEntry.from_record(@current)
        end

        # POST /registration/patients/:dfn/race_ethnicity
        def update
          @entry = RaceEthnicityEntry.from_params(race_ethnicity_params)
          unless @entry.valid?
            load_choices
            return render(:edit, status: :unprocessable_content)
          end

          result = PatientProfileGateway.set_race_ethnicity(@dfn, races: @entry.races, ethnicities: @entry.ethnicities)
          if result.saved?
            redirect_to registration_patient_path(@dfn, anchor: "race-ethnicity-section"), notice: "Race and ethnicity saved."
          else
            load_choices
            flash.now[:alert] = write_failure_message(result, "race and ethnicity")
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        private

        # races and ethnicities, each { "<ien>" => { "chosen", "method" } }.
        def race_ethnicity_params
          params.fetch(:race_ethnicity, {}).permit(races: {}, ethnicities: {}).to_h
        end

        # The choices RPMS offers, with anything already on file that is not
        # among them (an entry from before the current categories).
        def load_choices
          @current = PatientProfileGateway.race_ethnicity(@dfn)
          choices = PatientProfileGateway.race_ethnicity_choices
          @methods = choices[:methods]
          @options = RaceEthnicityEntry::KINDS.keys.to_h do |kind|
            on_file = Array(@current[kind]).map { |row| { ien: row[:ien], name: row[:name] } }
            [ kind, (Array(choices[kind]) + on_file).uniq { |row| row[:ien] } ]
          end
        end
      end
    end
  end
end
