# frozen_string_literal: true

require "rpms_rpc/api/registration_setup"

module Lakeraven
  module EHR
    # The registration tables a site keeps itself, which BPRM edits under
    # Settings > Table Maintenance: the eligibility modifiers a clerk picks as
    # proof of a name change, a legal document or legal sex (ELIGIBILITY
    # MODIFIERS, #9000030; lakeraven-ehr#982), and the site's local patient
    # record flags (PRF LOCAL FLAG, #26.11; #983). Everything goes through
    # RpmsRpc::RegistrationSetup, which files with FileMan (DDR FILER).
    #
    # Reads raise the gem's errors (RpmsUnavailableRendering answers them).
    # Writes answer a Result: an error mid-call is :unknown, because the write
    # may already have filed.
    class RegistrationSetupGateway
      Result = Data.define(:status, :message, :ien) do
        def saved? = status == :saved
        def unknown? = status == :unknown
        def partial? = status == :partial
      end

      # What a modifier's TYPE letters mean (#9000030 .02, its help text).
      TYPE_LETTERS = {
        "N" => "Name change", "L" => "Legal document", "S" => "Legal sex", "A" => "Advance directive",
        "I" => "Eligibility status", "C" => "Eligibility status", "D" => "Eligibility status", "P" => "Eligibility status"
      }.freeze

      class << self
        def eligibility_modifiers(via: ::RpmsRpc::RegistrationSetup)
          via.eligibility_modifier_table
        end

        # The types a new modifier may take, as BPRM offers them.
        def modifier_types(via: ::RpmsRpc::RegistrationSetup) = via::LEGAL_DOCUMENT_TYPES

        def type_label(type)
          type.to_s.chars.filter_map { |letter| TYPE_LETTERS[letter] }.uniq.join(", ").presence || type.to_s
        end

        def add_eligibility_modifier(name, type, via: ::RpmsRpc::RegistrationSetup)
          result_for(via.add_eligibility_modifier(name: name.to_s, type: type.to_s))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def rename_eligibility_modifier(ien, name, via: ::RpmsRpc::RegistrationSetup)
          result_for(via.rename_eligibility_modifier(ien.to_i, name: name.to_s))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        # The flag types this app does not file: Behavioral. A Behavioral flag on a
        # patient's banner can reveal behavioral health or substance use treatment
        # to every user, and whether one is segmented waits on the Part 2 decision
        # (#291). Until then a Behavioral flag is listed, and is not added, changed,
        # or made from another type here.
        WITHHELD_FLAG_TYPES = %w[BEHAVIORAL].freeze

        def withheld_type?(type) = WITHHELD_FLAG_TYPES.include?(type[:name].to_s.upcase)

        def flag_types(via: ::RpmsRpc::RegistrationSetup) = via.flag_types

        def local_flags(via: ::RpmsRpc::RegistrationSetup) = via.local_flags

        def local_flag(ien, via: ::RpmsRpc::RegistrationSetup) = via.local_flag(ien.to_i)

        def local_flag_history(ien, via: ::RpmsRpc::RegistrationSetup) = via.local_flag_history(ien.to_i)

        # entry: a valid LocalFlagEntry.
        def add_local_flag(entry, via: ::RpmsRpc::RegistrationSetup)
          result_for(via.add_local_flag(name: entry.name, type: entry.type_ien, review_days: entry.review_days,
                                        notification_days: entry.notification_days, description: entry.description_lines,
                                        active: entry.active))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def update_local_flag(ien, entry, via: ::RpmsRpc::RegistrationSetup)
          result_for(via.update_local_flag(ien.to_i, name: entry.name, type: entry.type_ien, review_days: entry.review_days,
                                           notification_days: entry.notification_days, active: entry.active,
                                           reason: entry.reason_lines, description: entry.description_lines))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        private

        def result_for(reply)
          return Result.new(status: :unknown, message: nil, ien: nil) if reply.nil?
          return Result.new(status: :saved, message: nil, ien: reply[:ien]) if reply[:success]

          status = { partial: :partial, not_found: :not_found }.fetch(reply[:error], :refused)
          Result.new(status: status, message: reply[:message].to_s, ien: nil)
        end

        def unknown(error)
          Rails.logger.error("[registration setup] write raised #{error.class}; the outcome is unknown")
          Result.new(status: :unknown, message: nil, ien: nil)
        end
      end
    end
  end
end
