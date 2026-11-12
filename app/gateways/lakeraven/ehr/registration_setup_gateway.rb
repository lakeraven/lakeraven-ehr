# frozen_string_literal: true

require "rpms_rpc/api/registration_setup"

module Lakeraven
  module EHR
    # The registration tables a site keeps itself, which BPRM edits under
    # Settings > Table Maintenance: the eligibility modifiers a clerk picks as
    # proof of a name change, a legal document or legal sex (ELIGIBILITY
    # MODIFIERS, #9000030; lakeraven-ehr#982). Everything goes through
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
