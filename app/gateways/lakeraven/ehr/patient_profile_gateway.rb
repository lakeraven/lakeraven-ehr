# frozen_string_literal: true

require "rpms_rpc/api/patient_profile"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    # The parts of a registration beside the demographics: the emergency
    # contact and next of kin (rpms-ux S-REG-08), the other tribes and eligibility
    # modifiers (S-REG-07.2, S-REG-07.3), the languages (S-REG-10) and
    # the other names and the preferred name (S-REG-12), and race and ethnicity (S-REG-20.2). Everything goes through RpmsRpc::PatientProfile,
    # which reads and files through AG's own windows and runs AG's own field
    # checks (AGG WINDOW DATA VALIDATION) before it files.
    #
    # Reads raise the gem's errors (RpmsUnavailableRendering answers them).
    # Writes answer a Result: an error mid-call is :unknown, because the write
    # may already have filed.
    class PatientProfileGateway
      Result = Data.define(:status, :field, :message) do
        def saved? = status == :saved
        def unknown? = status == :unknown
        def partial? = status == :partial
      end

      LOOKUP_LIMIT = 25

      class << self
        def contacts(dfn, via: ::RpmsRpc::PatientProfile)
          via.contacts(dfn.to_i) || raise(::RpmsRpc::Client::ConnectionError, "no reply to the contacts read")
        end

        # changes: only the fields the clerk changed (see ContactEntry#changes_from).
        def update_contact(dfn, kind, changes, via: ::RpmsRpc::PatientProfile)
          result_for(via.update_contact(dfn.to_i, kind.to_sym, **changes))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def languages(dfn, via: ::RpmsRpc::PatientProfile)
          via.languages(dfn.to_i) || raise(::RpmsRpc::Client::ConnectionError, "no reply to the languages read")
        end

        def record_languages(dfn, entry, via: ::RpmsRpc::PatientProfile)
          result_for(via.record_languages(dfn.to_i, **entry.record_attrs))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # The latest migrant, homeless and internet answers (S-REG-11, S-REG-31.3).
        def social_status(dfn, via: ::RpmsRpc::PatientProfile)
          via.social_status(dfn.to_i) || raise(::RpmsRpc::Client::ConnectionError, "no reply to the social status read")
        end

        def record_social_status(dfn, entry, via: ::RpmsRpc::PatientProfile)
          result_for(via.record_social_status(dfn.to_i, **entry.record_attrs))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def aliases(dfn, via: ::RpmsRpc::PatientProfile)
          via.aliases(dfn.to_i) || raise(::RpmsRpc::Client::ConnectionError, "no reply to the other names read")
        end

        def add_alias(dfn, name, via: ::RpmsRpc::PatientProfile)
          result_for(via.add_alias(dfn.to_i, name))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def remove_alias(dfn, ien, via: ::RpmsRpc::PatientProfile)
          result_for(via.remove_alias(dfn.to_i, ien.to_i))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # The patient's tribe, enrollment and eligibility status as registration
        # shows them, or nil. The registration screens' ungated read of the
        # same RPC as TribalEnrollmentGateway.enrollment_details: those screens
        # never were gated on tribal_enrollment, and moving them under that
        # capability would be a behaviour change outside this slice.
        def enrollment(dfn, via: ::RpmsRpc::Tribal)
          via.enrollment(dfn)
        end

        # The patient's other tribes (S-REG-07.2).
        def other_tribes(dfn, via: ::RpmsRpc::PatientProfile)
          via.other_tribes(dfn.to_i) || raise(::RpmsRpc::Client::ConnectionError, "no reply to the other tribes read")
        end

        def add_other_tribe(dfn, entry, via: ::RpmsRpc::PatientProfile)
          result_for(via.add_other_tribe(dfn.to_i, tribe: entry.tribe_ien, quantum: entry.quantum.to_s))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def remove_other_tribe(dfn, ien, via: ::RpmsRpc::PatientProfile)
          result_for(via.remove_other_tribe(dfn.to_i, ien.to_i))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # The reasons behind the patient's eligibility status (S-REG-07.3). RPMS
        # has no registration call for them; RpmsRpc::Registration files them the
        # way ADDMOD^AGED11A does, under AG's edit lock.
        def eligibility_modifiers(dfn, via: ::RpmsRpc::Registration)
          via.eligibility_modifiers(dfn.to_i)
        end

        def eligibility_modifier_choices(status, via: ::RpmsRpc::Registration)
          status.present? ? via.eligibility_modifier_choices(status) : []
        end

        def add_eligibility_modifier(dfn, modifier, via: ::RpmsRpc::Registration)
          result_for(via.add_eligibility_modifier(dfn.to_i, modifier.to_i))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def remove_eligibility_modifier(dfn, modifier, via: ::RpmsRpc::Registration)
          result_for(via.remove_eligibility_modifier(dfn.to_i, modifier.to_i))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # The name the patient goes by (S-REG-12.1): "" when none is on file.
        # RPMS has no registration call for it; RpmsRpc::Registration files it
        # the way $$SETPREF^AUPNSOGI does, under AG's edit lock (openrpms#1059).
        def preferred_name(dfn, via: ::RpmsRpc::Registration)
          via.preferred_name(dfn.to_i)
        end

        def set_preferred_name(dfn, name, via: ::RpmsRpc::Registration)
          result_for(via.set_preferred_name(dfn.to_i, name))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # The patient's races and ethnicities, each with how it was collected
        # (S-REG-20.2), and the ones a clerk picks from. RPMS has no registration
        # call for them; RpmsRpc::Registration files them the way AG's page 10
        # does, under AG's edit lock (openrpms#1055).
        def race_ethnicity(dfn, via: ::RpmsRpc::Registration) = via.race_ethnicity(dfn.to_i)
        def race_ethnicity_choices(via: ::RpmsRpc::Registration) = via.race_ethnicity_choices

        # races and ethnicities: [{ code:, method: }] (see RaceEthnicityEntry).
        def set_race_ethnicity(dfn, races:, ethnicities:, via: ::RpmsRpc::Registration)
          result_for(via.set_race_ethnicity(dfn.to_i, races: races, ethnicities: ethnicities))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # Look-ups by the start of a name: relationships, states and languages.
        def relationships(text, via: ::RpmsRpc::PatientProfile) = lookup(text) { |t| via.relationships(t) }
        def states(text, via: ::RpmsRpc::PatientProfile) = lookup(text) { |t| via.states(t) }
        def language_lookup(text, via: ::RpmsRpc::PatientProfile) = lookup(text) { |t| via.language_lookup(t) }

        # LANGUAGE (#9999999.99) ENGLISH, which the language rules turn on.
        def english_ien(via: ::RpmsRpc::PatientProfile)
          Array(via.language_lookup("ENGLISH")).find { |row| row[:name] == "ENGLISH" }&.dig(:ien)
        end

        private

        def lookup(text)
          text = text.to_s.strip
          return [] if text.empty?

          Array(yield(text)).first(LOOKUP_LIMIT)
        end

        def result_for(reply)
          return Result.new(status: :unknown, field: nil, message: nil) if reply.nil?
          return Result.new(status: :saved, field: nil, message: nil) if reply[:success]

          status = reply[:error] == :partial ? :partial : :refused
          Result.new(status: status, field: reply[:field], message: reply[:message].to_s)
        end

        def unknown(error)
          Rails.logger.error("[registration] profile write raised #{error.class}; the outcome is unknown")
          Result.new(status: :unknown, field: nil, message: nil)
        end
      end
    end
  end
end
