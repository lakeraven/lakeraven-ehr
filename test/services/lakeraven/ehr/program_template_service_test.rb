# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ProgramTemplateServiceTest < ActiveSupport::TestCase
      # =========================================================================
      # TEMPLATE REGISTRY
      # =========================================================================

      test "TEMPLATES contains immunization program" do
        assert ProgramTemplateService::TEMPLATES.key?("immunization")
      end

      test "TEMPLATES contains sti program" do
        assert ProgramTemplateService::TEMPLATES.key?("sti")
      end

      test "TEMPLATES contains tb program" do
        assert ProgramTemplateService::TEMPLATES.key?("tb")
      end

      test "TEMPLATES contains neonatal program" do
        assert ProgramTemplateService::TEMPLATES.key?("neonatal")
      end

      test "TEMPLATES contains lead program" do
        assert ProgramTemplateService::TEMPLATES.key?("lead")
      end

      test "TEMPLATES contains hep_b program" do
        assert ProgramTemplateService::TEMPLATES.key?("hep_b")
      end

      test "TEMPLATES contains communicable_disease program" do
        assert ProgramTemplateService::TEMPLATES.key?("communicable_disease")
      end

      test "TEMPLATES is frozen" do
        assert ProgramTemplateService::TEMPLATES.frozen?
      end

      # =========================================================================
      # TEMPLATE STRUCTURE
      # =========================================================================

      test "each template has required keys" do
        ProgramTemplateService::TEMPLATES.each do |program, milestones|
          milestones.each do |ms|
            assert ms.key?(:key), "#{program} milestone missing :key"
            assert ms.key?(:description), "#{program} milestone missing :description"
            assert ms.key?(:due_days_from_anchor), "#{program} milestone missing :due_days_from_anchor"
            assert ms.key?(:required), "#{program} milestone missing :required"
            assert ms.key?(:priority), "#{program} milestone missing :priority"
          end
        end
      end

      test "hep_b template has 5 milestones" do
        assert_equal 5, ProgramTemplateService::TEMPLATES["hep_b"].length
      end

      test "tb template has 6 milestones" do
        assert_equal 6, ProgramTemplateService::TEMPLATES["tb"].length
      end

      test "all templates are individually frozen" do
        ProgramTemplateService::TEMPLATES.each do |_program, milestones|
          assert milestones.frozen?, "Expected milestones array to be frozen"
        end
      end
    end
  end
end
