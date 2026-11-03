# frozen_string_literal: true

require "rpms_rpc/api/coverage"
require "rpms_rpc/api/ddr_fileman"

module Lakeraven
  module EHR
    # A patient's Medicaid, Medicare and private insurance, as the front desk
    # records it for billing (rpms-ux S-REG-03). Everything goes through AG's
    # own registration windows (RpmsRpc::Coverage): the reads AG's client fills
    # its Medicaid, Medicare and Private Insurance windows with, and its
    # AGG UPDATE MEDICAID / MEDICARE / PRIVATE INSUR writes. AG decides what
    # is in force today (MCDACT/MCRACT/PVTACT^AGGARVAL); nothing here
    # recomputes it.
    class CoverageGateway
      # One coverage as the front desk reads it.
      Policy = Data.define(:kind, :payer, :number, :detail, :periods, :active) do
        def ends_on = periods.filter_map { |p| p[:ends_on] }.max
      end

      Result = Data.define(:status, :message) do
        def filed? = status == :filed
        def outcome_unknown? = status == :unknown
      end

      KIND_LABELS = { medicaid: "Medicaid", medicare: "Medicare", private: "Private insurance" }.freeze
      PICK_LIMIT = 25

      # [Policy] for the patient, Medicaid first, or nil when RPMS gave no
      # answer. Raises what the gem raises on a refusal (RpcRefusedError).
      def self.on_file(dfn, via: ::RpmsRpc::Coverage)
        found = via.on_file(dfn.to_i)
        return nil if found.nil?

        Array(found[:medicaid]).map { |c| public_program(:medicaid, c, c[:state].presence) } +
          Array(found[:medicare]).map { |c| public_program(:medicare, c, c[:suffix].presence) } +
          Array(found[:private]).map { |c| private_policy(c) }
      end

      # What a check-in should say about coverage (S-REG-03.2):
      #   :in_force   some coverage is in force today
      #   :lapsed     coverage is on file and none of it is in force today
      #   :none       no coverage on file
      #   :unchecked  RPMS would not answer, or refused this user the read
      def self.standing(dfn, via: ::RpmsRpc::Coverage)
        policies = on_file(dfn, via: via)
        return :unchecked if policies.nil?
        return :none if policies.empty?

        policies.any?(&:active) ? :in_force : :lapsed
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.warn("[coverage] standing read failed: #{e.class}")
        :unchecked
      end

      # Files one coverage. entry is a CoverageEntry that has been validated.
      def self.add(dfn, entry, patient_name:, via: ::RpmsRpc::Coverage)
        reply = case entry.kind
        when "medicaid"
          via.add_medicaid(dfn.to_i, number: entry.number, state_ien: entry.state_ien, coverage: nil,
                                     effective_on: wire_date(entry.starts_on), ends_on: wire_date(entry.ends_on))
        when "medicare"
          via.add_medicare(dfn.to_i, name: patient_name, number: entry.number, part: entry.part,
                                     effective_on: wire_date(entry.starts_on), ends_on: wire_date(entry.ends_on))
        when "private"
          via.add_private_insurance(dfn.to_i, insurer_ien: entry.insurer_ien, policy_holder: entry.policy_holder,
                                              member_number: entry.number,
                                              effective_on: wire_date(entry.starts_on), ends_on: wire_date(entry.ends_on))
        end
        result_for(reply)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        # The add may have filed before the error: never say it did not.
        Rails.logger.error("[coverage] add raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, message: nil)
      end

      # The insurers a private policy can name: AG's insurer pick, private
      # types only, those whose name starts with the text.
      def self.private_insurers(part, via: ::RpmsRpc::Coverage)
        text = part.to_s.strip.upcase
        return [] if text.empty?

        Array(via.insurers).select { |i| i[:type] == "PRIVATE" && i[:name].to_s.start_with?(text) }.first(PICK_LIMIT)
      end

      # STATE (#5) entries whose name starts with the text: [{ ien:, name: }].
      def self.states(part, via: ::RpmsRpc::DdrFileman)
        text = part.to_s.strip.upcase
        return [] if text.empty?

        got = via.lister(file: "5", fields: "@;.01", flags: "IP", xref: "B", part: text, max: PICK_LIMIT.to_s)
        return [] if got.nil? || got[:error]

        got[:entries].map { |row| { ien: row[:ien], name: Array(row[:pieces]).first.to_s } }
      end

      def self.public_program(kind, coverage, detail)
        periods = Array(coverage[:eligibility]).map { |e| e.slice(:starts_on, :ends_on, :coverage) }
        Policy.new(kind: kind, payer: coverage[:payer], number: coverage[:number], detail: detail,
                   periods: periods, active: coverage[:active] == true)
      end

      def self.private_policy(coverage)
        Policy.new(kind: :private, payer: coverage[:payer], number: coverage[:number],
                   detail: coverage[:policy_holder].presence,
                   periods: [ coverage.slice(:starts_on, :ends_on) ], active: coverage[:active] == true)
      end

      def self.result_for(reply)
        return Result.new(status: :unknown, message: nil) if reply.nil?
        return Result.new(status: :filed, message: nil) if reply[:success]

        Result.new(status: :refused, message: reply[:message].to_s)
      end

      def self.wire_date(date) = date&.strftime("%m/%d/%Y")

      private_class_method :public_program, :private_policy, :result_for, :wire_date
    end
  end
end
