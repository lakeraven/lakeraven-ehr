# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # Recording the patient's languages (rpms-ux S-REG-10), shown on the patient's
      # registration page (languages/_section). Each save is a new dated entry in
      # RPMS; the earlier ones are kept.
      class LanguagesController < PatientSectionController
        EDIT_ACTIONS = %w[edit update].freeze

        rate_limit only: %i[edit update]

        # GET or POST /registration/patients/:dfn/languages/edit. A POST is a
        # language look-up, and carries what the clerk has chosen so far.
        def edit
          if request.post?
            build_from_params
          else
            current = PatientProfileGateway.languages(@dfn)
            @entry = LanguageEntry.from_rpms(current)
            @names = names_from(current)
          end
          load_form
        end

        # POST /registration/patients/:dfn/languages
        def update
          build_from_params
          load_form
          return render(:edit, status: :unprocessable_content) unless @entry.valid?

          if @entry.needs_preferred_confirmation?
            @confirm_preferred = true
            return render(:edit, status: :unprocessable_content)
          end

          result = PatientProfileGateway.record_languages(@dfn, @entry)
          if result.saved?
            redirect_to registration_patient_path(@dfn, anchor: "languages-section"), notice: "Languages saved."
          else
            flash.now[:alert] = write_failure_message(result, "languages")
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        private

        def build_from_params
          attrs = params.fetch(:languages, {}).permit(:primary_ien, :preferred_ien, :interpreter, :proficiency, :preferred_confirmed, others: [])
          @entry = LanguageEntry.new(attrs.to_h)
          @names = params.fetch(:language_names, {}).permit!.to_h.transform_keys(&:to_i)
        end

        def load_form
          @entry.english_ien = PatientProfileGateway.english_ien
          @found = {}
          %i[primary_search preferred_search other_search].each do |search|
            @found[search] = PatientProfileGateway.language_lookup(params[search])
            @found[search].each { |row| @names[row[:ien]] = row[:name] }
          end
          @names[@entry.english_ien] ||= "ENGLISH" if @entry.english_ien
        end

        def names_from(languages)
          pointers = [ languages[:primary], languages[:preferred], *Array(languages[:others]) ].compact
          pointers.to_h { |row| [ row[:ien], row[:name] ] }
        end
      end
    end
  end
end
