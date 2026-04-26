# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class HepBWorkflowServiceTest < ActiveSupport::TestCase
      # =========================================================================
      # CREATE PERINATAL CASE
      # =========================================================================

      test "create_perinatal_case delegates to ProgramTemplateService" do
        called_with = nil
        pts = Class.new do
          define_method(:create_case) { |**kwargs| called_with = kwargs; :mock_case }
        end.new

        # Replace class method via define_singleton_method
        original = ProgramTemplateService.method(:create_case) if ProgramTemplateService.respond_to?(:create_case)
        ProgramTemplateService.define_singleton_method(:create_case) { |**kwargs| called_with = kwargs; :mock_case }

        result = HepBWorkflowService.create_perinatal_case(
          infant_dfn: "100", maternal_dfn: "200",
          facility: "ANMC", birth_date: Date.new(2026, 1, 15)
        )

        assert_equal :mock_case, result
        assert_equal "hep_b", called_with[:program_type]
        assert_equal "100", called_with[:patient_id]
        assert_equal "ANMC", called_with[:facility]
        assert_equal Date.new(2026, 1, 15), called_with[:anchor_date]
        assert_equal({ "maternal_dfn" => "200" }, called_with[:program_data])
      ensure
        if original
          ProgramTemplateService.define_singleton_method(:create_case, original)
        end
      end

      # =========================================================================
      # RECORD MILESTONES
      # =========================================================================

      test "record_hbig_administration completes the hbig milestone" do
        milestone = build_mock_milestone("hbig_administration")
        kase = build_mock_case([ milestone ])

        result = HepBWorkflowService.record_hbig_administration(
          kase: kase, administered_at: Time.new(2026, 1, 15, 8, 0, 0),
          performer_ien: "301"
        )

        assert_equal :completed, milestone.status
        assert result
      end

      test "record_birth_dose completes the birth_dose milestone" do
        milestone = build_mock_milestone("birth_dose")
        kase = build_mock_case([ milestone ])

        HepBWorkflowService.record_birth_dose(
          kase: kase, administered_at: Time.new(2026, 1, 15, 9, 0, 0),
          performer_ien: "301"
        )

        assert_equal :completed, milestone.status
      end

      test "record_vaccine_dose completes specified dose milestone" do
        milestone = build_mock_milestone("dose_2")
        kase = build_mock_case([ milestone ])

        HepBWorkflowService.record_vaccine_dose(
          kase: kase, dose_key: "dose_2",
          administered_at: Time.new(2026, 2, 15, 10, 0, 0),
          performer_ien: "301"
        )

        assert_equal :completed, milestone.status
      end

      # =========================================================================
      # RECORD PVST
      # =========================================================================

      test "record_pvst stores serologic results in program_data" do
        milestone = build_mock_milestone("pvst")
        program_data = {}
        kase = build_mock_case([ milestone ], program_data: program_data)

        HepBWorkflowService.record_pvst(
          kase: kase, hbsag_result: "negative",
          anti_hbs_result: "positive",
          tested_at: Time.new(2026, 10, 15),
          performer_ien: "301"
        )

        assert_equal "negative", program_data[:pvst_hbsag_result]
        assert_equal "positive", program_data[:pvst_anti_hbs_result]
        assert_equal :completed, milestone.status
      end

      # =========================================================================
      # CASE COMPLETION
      # =========================================================================

      test "case_complete? returns true when all required milestones done" do
        kase = build_mock_case_for_completion(incomplete_count: 0)
        assert HepBWorkflowService.case_complete?(kase)
      end

      test "case_complete? returns false when required milestones remain" do
        kase = build_mock_case_for_completion(incomplete_count: 2)
        refute HepBWorkflowService.case_complete?(kase)
      end

      # =========================================================================
      # TRY CLOSE CASE
      # =========================================================================

      test "try_close_case returns true and advances when complete" do
        kase = build_mock_case_for_completion(incomplete_count: 0)
        advanced = false
        kase.define_singleton_method(:advance_to!) { |_status, **_opts| advanced = true }

        assert HepBWorkflowService.try_close_case(kase)
        assert advanced
      end

      test "try_close_case returns false when incomplete" do
        kase = build_mock_case_for_completion(incomplete_count: 1)

        refute HepBWorkflowService.try_close_case(kase)
      end

      test "record_hbig_administration raises when milestone not found" do
        kase = build_mock_case([])

        assert_raises(RuntimeError) do
          HepBWorkflowService.record_hbig_administration(
            kase: kase, administered_at: Time.now, performer_ien: "301"
          )
        end
      end

      private

      def build_mock_milestone(key)
        ms = Object.new
        ms.instance_variable_set(:@milestone_key, key)
        ms.instance_variable_set(:@status, :pending)
        ms.instance_variable_set(:@completed_at, nil)
        ms.instance_variable_set(:@notes, nil)
        ms.define_singleton_method(:milestone_key) { @milestone_key }
        ms.define_singleton_method(:status) { @status }
        ms.define_singleton_method(:update!) do |attrs|
          @status = attrs[:status] if attrs.key?(:status)
          @completed_at = attrs[:completed_at] if attrs.key?(:completed_at)
          @notes = attrs[:notes] if attrs.key?(:notes)
        end
        ms
      end

      def build_mock_case(milestones, program_data: {})
        kase = Object.new
        kase.instance_variable_set(:@program_data, program_data)
        kase.instance_variable_set(:@id, 999)

        # milestones query object
        milestones_query = Object.new
        milestones_query.instance_variable_set(:@milestones, milestones)
        milestones_query.define_singleton_method(:find_by!) do |attrs|
          found = @milestones.find { |m| m.milestone_key == attrs[:milestone_key] }
          raise "Milestone not found: #{attrs[:milestone_key]}" unless found
          found
        end

        kase.define_singleton_method(:milestones) { milestones_query }
        kase.define_singleton_method(:id) { @id }
        kase.define_singleton_method(:set_program_datum) do |key, value|
          @program_data[key] = value
        end
        kase
      end

      def build_mock_case_for_completion(incomplete_count:)
        kase = Object.new
        required_scope = Object.new
        incomplete_scope = Object.new

        items = Array.new(incomplete_count, :placeholder)
        incomplete_scope.define_singleton_method(:none?) { items.empty? }

        required_scope.define_singleton_method(:incomplete) { incomplete_scope }

        milestones = Object.new
        milestones.define_singleton_method(:where) { |**_args| required_scope }

        kase.define_singleton_method(:milestones) { milestones }
        kase
      end
    end
  end
end
