# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    # Registering a new patient (rpms-ux S-REG-02) through RpmsRpc::Patient.register:
    # AG's own add (AGG ADD NEW PATIENT), after the gem's candidate lookup. The
    # gem decides identity: a name or date of birth already on file comes back as
    # :duplicate_identity with the candidates' DFNs, and only allow_duplicate:
    # true, after a person has reviewed them, files anyway. Nothing here second-
    # guesses that answer.
    class PatientRegistrationGateway
      Result = Data.define(:status, :dfn, :candidate_dfns, :message) do
        def registered? = status == :registered
        def possible_matches? = status == :possible_matches
        def hrn_not_filed? = status == :hrn_not_filed
        def outcome_unknown? = status == :unknown
      end

      PICK_LIMIT = 25

      def self.register(registration, allow_duplicate: false, via: ::RpmsRpc::Patient)
        attrs = registration.register_attrs
        attrs = attrs.merge(allow_duplicate: true) if allow_duplicate == true
        result_for(via.register(attrs))
      rescue ::RpmsRpc::Client::RpcError, ::RpmsRpc::Client::ConnectionError, IOError, SystemCallError => e
        # An error mid-call: the add may already have filed (the gem says so for a
        # frame error), so the outcome is unknown, never "not registered".
        Rails.logger.error("[registration] register raised #{e.class}; the outcome is unknown")
        unknown
      end

      # The tribes and communities whose names start with the text, for the
      # clerk to choose from. Empty text lists nothing.
      def self.tribes(part, via: ::RpmsRpc::Tribal)
        return [] if part.to_s.strip.empty?

        Array(via.tribes(part: part.to_s.strip.upcase)).first(PICK_LIMIT)
      end

      def self.communities(part, via: ::RpmsRpc::Tribal)
        return [] if part.to_s.strip.empty?

        Array(via.communities(part: part.to_s.strip.upcase)).first(PICK_LIMIT)
      end

      def self.result_for(reply)
        # No answer: the add may have filed, so a retry could file a second chart.
        return unknown if reply.nil?
        return Result.new(status: :registered, dfn: reply[:dfn], candidate_dfns: [], message: nil) if reply[:success]

        # The chart was filed and only the health record number failed: the
        # patient exists, so say where, not "not registered".
        if reply[:error] == :hrn_file_failed && reply[:dfn]
          return Result.new(status: :hrn_not_filed, dfn: reply[:dfn], candidate_dfns: [], message: reply[:message].to_s)
        end

        if reply[:error] == :duplicate_identity
          return Result.new(status: :possible_matches, dfn: nil, candidate_dfns: Array(reply[:candidate_dfns]), message: nil)
        end

        Result.new(status: :refused, dfn: nil, candidate_dfns: [], message: reply[:message].to_s)
      end

      def self.unknown = Result.new(status: :unknown, dfn: nil, candidate_dfns: [], message: nil)
      private_class_method :result_for, :unknown
    end
  end
end
