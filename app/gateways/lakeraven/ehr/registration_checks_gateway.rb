# frozen_string_literal: true

require "rpms_rpc/api/agg"

module Lakeraven
  module EHR
    # What is missing or wrong on a patient's registration (rpms-ux S-REG-23,
    # S-REG-31): AG's own edit checks, AGG PATIENT EDIT CHECK (CHK^AGGEDCHK),
    # through RpmsRpc::Agg.edit_check. It is the list BPRM shows as a patient's
    # errors and warnings (its AgGetPatientErrorsAndWarnings calls the same
    # routine). AG decides what is checked, and for whom: the site's error
    # table (^AGEDERRS) and the patient's own details. Nothing is added or
    # dropped here.
    #
    # AG marks each item ERROR, MANDATORY (its own data checks, 800-813,
    # AGGEDCHK.m:85-102) or WARNING. The first two are errors; a warning is a
    # question not yet asked. Each names the AG window it is fixed in, which is
    # the section of the registration it belongs to.
    class RegistrationChecksGateway
      Item = Data.define(:number, :message, :kind, :section) do
        def error? = kind == :error
        def warning? = kind == :warning
      end

      Result = Data.define(:items) do
        def available? = !items.nil?
        def errors = items.select(&:error?)
        def warnings = items.select(&:warning?)
        def by_section = items.group_by(&:section)
      end

      ERROR_TYPES = %w[ERROR MANDATORY].freeze

      # AG's window name => the section of the registration, in the clerk's
      # words. A window not listed is shown by its own name.
      SECTIONS = {
        "Personal Detail" => "Personal details",
        "Address" => "Address and phone",
        "Eligibility" => "Eligibility and tribe",
        "Other Patient" => "Other patient information"
      }.freeze

      # The patient's items, or a Result whose items are nil when RPMS gave no
      # answer: "could not check" never reads as "nothing missing".
      def self.for(dfn, via: ::RpmsRpc::Agg)
        reply = via.edit_check(dfn: dfn.to_i)
        return Result.new(items: nil) if reply.nil?

        Result.new(items: Array(reply[:checks]).map { |check| item(check) })
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[registration] edit check failed: #{e.class}")
        Result.new(items: nil)
      end

      def self.item(check)
        window = check[:hide_window].to_s.strip
        Item.new(
          number: check[:hide_error_num].to_s,
          message: check[:msg].to_s.strip,
          kind: ERROR_TYPES.include?(check[:type].to_s.upcase) ? :error : :warning,
          section: SECTIONS.fetch(window) { window.presence || "Other" }
        )
      end
      private_class_method :item
    end
  end
end
