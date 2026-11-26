# frozen_string_literal: true

require "rpms_rpc/api/problem"
require "rpms_rpc/api/pov"

module Lakeraven
  module EHR
    # A provider adds the diagnosis they found (Find a diagnosis, BSTS) to the
    # patient's problem list and, when it is why the patient came, as the
    # purpose of visit on one of today's open visits (rpms-ux S-VIS-02.2,
    # S-VIS-02.3). RPMS files both as VueCentric's problem entry does, as the
    # connection's signed-on user:
    #
    # 1. BGOPROB2 DUPCHK: is the concept, for its laterality, on the list
    #    already? RPMS answers the problems that hold it, or the concept as a
    #    new entry, with its description and the ICD-10-CM codes BSTS maps.
    # 2. BGOPROB SET through ConditionGateway.add, whose ICD-10-CM F10-F19
    #    refusal still applies: the concept, its description, the first code
    #    BSTS maps (RPMS files the other mapped codes itself), the status and
    #    the laterality.
    # 3. BGOVPOV SET through PovGateway.add, against the new problem. RPMS
    #    decides primary or secondary and takes the laterality from the
    #    problem.
    #
    # Nothing is called filed until it is read back: the problem from the
    # patient's integrated problem list (BGOPROB GET), the purpose of visit
    # from the visit's diagnoses (BGOVPOV GET), filed against the problem.
    # The result carries what RPMS stored, for the page to show.
    class ProblemEntryGateway
      # The statuses BGOPROB SET files, by the names VueCentric offers.
      STATUSES = %w[Chronic Sub-acute Episodic Social/Environmental Routine/Admin Inactive].freeze
      # What RPMS files when none is sent and the concept has no default
      # (PROB^BGOPROB3).
      DEFAULT_STATUS = "Episodic"
      LATERALITIES = ::RpmsRpc::Problem::LATERALITY.keys.freeze
      # Every IHS status, so a problem filed Inactive is read back too.
      EVERY_STATUS = "ASEORIP"
      WRITE_ERRORS = [ ::RpmsRpc::Error, IOError, SystemCallError ].freeze

      # outcome:
      #   :filed         the problem, and the purpose of visit when asked, are
      #                  in RPMS, read back
      #   :problem_only  the problem is in RPMS, read back; RPMS did not file
      #                  the purpose of visit (reason)
      #   :pov_unknown   the problem is in RPMS; whether the purpose of visit
      #                  was filed is not known
      #   :duplicate     RPMS holds the concept on the list (on_file); nothing sent
      #   :refused       RPMS, or the shared list's F10-F19 rule, refused the
      #                  problem: nothing filed (reason)
      #   :forbidden     RPMS refused this user the RPC (reason): nothing filed
      #   :unknown       an error after the problem was sent, or a read-back
      #                  that does not show it: whether it was filed is not known
      Result = Struct.new(:outcome, :problem, :diagnoses, :on_file, :reason, keyword_init: true) do
        def filed? = outcome == :filed
        def problem_filed? = %i[filed problem_only pov_unknown].include?(outcome)
      end

      # What RPMS answers for the concept on the patient's list, before
      # anything is written: { on_file: [...], new_entry: {...} }.
      def self.check(dfn, concept_id, laterality: nil)
        ::RpmsRpc::Problem.duplicate_check(dfn.to_s, concept_id.to_s, laterality: laterality.presence)
      end

      # The INSTITUTION the session signed on to, which numbers the problem
      # (DUZ(2)); nil when the session has none.
      def self.location_ien
        client = BackendRegistry.current.client
        ien = client.respond_to?(:division) ? client.division&.dig(:ien) : nil
        ien.to_s if ien.to_i.positive?
      end

      def self.add(dfn, concept_id:, status:, laterality: nil, visit_ien: nil, provider_duz: nil)
        CapabilityGuard.ensure!(:pcc_screens)
        dfn = dfn.to_s
        entry, refusal = new_entry(dfn, concept_id, laterality)
        return refusal if refusal

        location = location_ien
        return Result.new(outcome: :refused, reason: "The session has no division to number the problem under.") unless location

        problem = file_problem(dfn, concept_id, entry, status, laterality, location)
        return problem if problem.is_a?(Result)
        return Result.new(outcome: :filed, problem: problem, diagnoses: []) if visit_ien.blank?

        file_purpose_of_visit(dfn, visit_ien.to_s, problem, entry, provider_duz)
      end

      # The patient's problem by IEN, from the integrated list, or nil when it
      # is not this patient's (or not on file).
      def self.problem(dfn, ien)
        ::RpmsRpc::Problem.integrated(dfn.to_s, statuses: EVERY_STATUS).find { |row| row[:ien].to_s == ien.to_s }
      end

      # Whether every code is ICD-10-CM outside F10-F19 (and the other
      # substance use codes Icd10CmSubstanceUseRange names), so the problem may
      # sit on the shared list and these pages may show it. No code is not.
      def self.shareable?(codes)
        codes = Array(codes).compact_blank
        codes.any? && codes.all? { |code| Icd10CmSubstanceUseRange.classify(icd_code: code) == :not_sud }
      end

      # The ICD-10-CM codes a problem RPMS stored carries.
      def self.problem_codes(problem) = [ problem[:icd_code], *problem[:additional_icd].to_s.split(";") ].compact_blank

      # The side a laterality pair RPMS stored names (Left, Right,
      # Bilateral), or the pair as stored when it names none of them.
      def self.side(pair) = ::RpmsRpc::Problem::LATERALITY.key(pair.to_s) || pair.to_s

      # The visit's diagnoses filed against the problem.
      def self.diagnoses(visit_ien, problem_ien)
        ::RpmsRpc::Pov.for_visit(visit_ien.to_s).select { |row| row[:problem_ien].to_s == problem_ien.to_s }
      end

      def self.new_entry(dfn, concept_id, laterality)
        check = check(dfn, concept_id, laterality: laterality)
        return [ nil, Result.new(outcome: :duplicate, on_file: check[:on_file]) ] if check[:on_file].any?

        entry = check[:new_entry]
        return [ nil, Result.new(outcome: :refused, reason: "RPMS's terminology maps no ICD-10-CM code to this concept.") ] if entry.nil? || entry[:icd_codes].blank?

        [ entry, nil ]
      rescue ::RpmsRpc::Client::RpcRefusedError => e
        [ nil, Result.new(outcome: :forbidden, reason: RpcSupport.sanitize(e.message)) ]
      end
      private_class_method :new_entry

      def self.file_problem(dfn, concept_id, entry, status, laterality, location)
        filed = ConditionGateway.add(dfn, {
          snomed_ct: concept_id.to_s, descriptive_ct: entry[:description_id], icd_code: entry[:icd_codes].first,
          description: entry[:narrative], location_ien: location, status: status, laterality: laterality.presence
        })
        return problem_refused(filed) unless filed.is_a?(Hash) && filed[:success]

        problem(dfn, filed[:ien]) || unknown("RPMS answered problem #{filed[:ien]}, but the patient's problem list does not show it.")
      rescue ::RpmsRpc::Client::RpcRefusedError => e
        Result.new(outcome: :forbidden, reason: RpcSupport.sanitize(e.message))
      rescue *WRITE_ERRORS => e
        Rails.logger.error("[problem_entry] problem write raised #{e.class}")
        unknown(nil)
      end
      private_class_method :file_problem

      def self.file_purpose_of_visit(dfn, visit_ien, problem, entry, provider_duz)
        filed = PovGateway.add(dfn, visit_ien, entry[:icd_codes].first, narrative: entry[:narrative], modifiers: {
          problem_ien: problem[:ien], snomed_ct: problem[:snomed_concept], descriptive_ct: entry[:description_id],
          provider_duz: provider_duz
        })
        unless filed.is_a?(Hash) && filed[:success]
          return Result.new(outcome: :problem_only, problem: problem, diagnoses: [], reason: rpms_reason(filed))
        end

        rows = diagnoses(visit_ien, problem[:ien])
        return Result.new(outcome: :pov_unknown, problem: problem, diagnoses: []) if rows.empty?

        Result.new(outcome: :filed, problem: problem, diagnoses: rows)
      rescue ::RpmsRpc::Client::RpcRefusedError => e
        Result.new(outcome: :problem_only, problem: problem, diagnoses: [], reason: RpcSupport.sanitize(e.message))
      rescue *WRITE_ERRORS => e
        Rails.logger.error("[problem_entry] purpose of visit write raised #{e.class}")
        Result.new(outcome: :pov_unknown, problem: problem, diagnoses: [])
      end
      private_class_method :file_purpose_of_visit

      def self.problem_refused(filed)
        return unknown("RPMS answered problem #{filed[:ien]}, but did not file it as asked.") if filed.is_a?(Hash) && filed[:ien]

        Result.new(outcome: :refused, reason: rpms_reason(filed))
      end
      private_class_method :problem_refused

      def self.unknown(reason) = Result.new(outcome: :unknown, reason: reason)
      private_class_method :unknown

      # RPMS's own text from a -n^text reply, or the gem's refusal.
      def self.rpms_reason(filed)
        return nil unless filed.is_a?(Hash)

        text = filed[:error].is_a?(String) ? filed[:error] : Array(filed[:raw]).first.to_s.split("^", 2).last
        text.present? ? RpcSupport.sanitize(text) : nil
      end
      private_class_method :rpms_reason
    end
  end
end
