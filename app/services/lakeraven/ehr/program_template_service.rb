# frozen_string_literal: true

module Lakeraven
  module EHR
    # ProgramTemplateService -- factory for program-specific case tracking
    #
    # Maintains frozen templates for public health programs and creates
    # Case + milestone Task records in a single transaction.
    #
    # Ported from rpms_redux ProgramTemplateService.
    class ProgramTemplateService
      TEMPLATES = {
        "immunization" => [
          { key: "initial_assessment", description: "Initial immunization assessment", due_days_from_anchor: 0, required: true, priority: :routine, documentation: [] },
          { key: "vaccine_schedule_review", description: "Review recommended vaccine schedule", due_days_from_anchor: 7, required: true, priority: :routine, documentation: [] },
          { key: "catch_up_doses", description: "Administer catch-up doses if needed", due_days_from_anchor: 30, required: false, priority: :routine, documentation: [ "vaccine_name", "lot_number" ] },
          { key: "follow_up_verification", description: "Verify immunization record completeness", due_days_from_anchor: 90, required: true, priority: :routine, documentation: [] }
        ].freeze,

        "sti" => [
          { key: "intake_screening", description: "Initial STI screening and intake", due_days_from_anchor: 0, required: true, priority: :urgent, documentation: [] },
          { key: "lab_results_review", description: "Review laboratory results", due_days_from_anchor: 7, required: true, priority: :urgent, documentation: [ "lab_result" ] },
          { key: "treatment_initiation", description: "Initiate treatment protocol", due_days_from_anchor: 14, required: true, priority: :urgent, documentation: [ "medication", "dosage" ] },
          { key: "partner_notification", description: "Partner notification and counseling", due_days_from_anchor: 14, required: true, priority: :routine, documentation: [] },
          { key: "test_of_cure", description: "Test of cure follow-up", due_days_from_anchor: 90, required: true, priority: :routine, documentation: [ "lab_result" ] }
        ].freeze,

        "tb" => [
          { key: "initial_screening", description: "Initial TB screening (TST/IGRA)", due_days_from_anchor: 0, required: true, priority: :urgent, documentation: [ "test_type", "result" ] },
          { key: "chest_xray", description: "Chest X-ray evaluation", due_days_from_anchor: 3, required: true, priority: :urgent, documentation: [ "radiology_result" ] },
          { key: "sputum_collection", description: "Sputum specimen collection", due_days_from_anchor: 3, required: true, priority: :urgent, documentation: [ "specimen_id" ] },
          { key: "treatment_initiation", description: "Initiate LTBI or active TB treatment", due_days_from_anchor: 14, required: true, priority: :urgent, documentation: [ "regimen" ] },
          { key: "monthly_follow_up", description: "Monthly treatment follow-up", due_days_from_anchor: 30, required: true, priority: :routine, documentation: [] },
          { key: "treatment_completion", description: "Treatment completion assessment", due_days_from_anchor: 270, required: true, priority: :routine, documentation: [] }
        ].freeze,

        "neonatal" => [
          { key: "birth_assessment", description: "Newborn assessment at birth", due_days_from_anchor: 0, required: true, priority: :stat, documentation: [] },
          { key: "hearing_screen", description: "Newborn hearing screening", due_days_from_anchor: 1, required: true, priority: :urgent, documentation: [ "result" ] },
          { key: "metabolic_screen", description: "Newborn metabolic screening", due_days_from_anchor: 2, required: true, priority: :urgent, documentation: [ "specimen_id" ] },
          { key: "two_week_visit", description: "Two-week well-child visit", due_days_from_anchor: 14, required: true, priority: :routine, documentation: [] },
          { key: "one_month_visit", description: "One-month well-child visit", due_days_from_anchor: 30, required: true, priority: :routine, documentation: [] }
        ].freeze,

        "lead" => [
          { key: "blood_lead_test", description: "Blood lead level testing", due_days_from_anchor: 0, required: true, priority: :urgent, documentation: [ "result_mcg_dl" ] },
          { key: "environmental_assessment", description: "Environmental lead source assessment", due_days_from_anchor: 14, required: true, priority: :routine, documentation: [] },
          { key: "nutritional_counseling", description: "Nutritional counseling for lead exposure", due_days_from_anchor: 14, required: true, priority: :routine, documentation: [] },
          { key: "follow_up_test", description: "Follow-up blood lead level", due_days_from_anchor: 90, required: true, priority: :routine, documentation: [ "result_mcg_dl" ] }
        ].freeze,

        "hep_b" => [
          { key: "hbig_administration", description: "HBIG administration within 12 hours of birth", due_days_from_anchor: 0, required: true, priority: :stat, documentation: [ "lot_number", "administered_by" ] },
          { key: "birth_dose", description: "Hepatitis B birth dose within 12 hours", due_days_from_anchor: 0, required: true, priority: :stat, documentation: [ "lot_number", "administered_by" ] },
          { key: "dose_2", description: "Hepatitis B dose 2 at 1 month", due_days_from_anchor: 30, required: true, priority: :urgent, documentation: [ "lot_number", "administered_by" ] },
          { key: "dose_3", description: "Hepatitis B dose 3 at 6 months", due_days_from_anchor: 180, required: true, priority: :routine, documentation: [ "lot_number", "administered_by" ] },
          { key: "pvst", description: "Post-vaccination serologic testing at 9-12 months", due_days_from_anchor: 300, required: true, priority: :routine, documentation: [ "hbsag_result", "anti_hbs_result" ] }
        ].freeze,

        "communicable_disease" => [
          { key: "case_investigation", description: "Initial case investigation and interview", due_days_from_anchor: 0, required: true, priority: :urgent, documentation: [] },
          { key: "contact_tracing", description: "Contact identification and tracing", due_days_from_anchor: 3, required: true, priority: :urgent, documentation: [] },
          { key: "lab_confirmation", description: "Laboratory confirmation of diagnosis", due_days_from_anchor: 7, required: true, priority: :urgent, documentation: [ "lab_result" ] },
          { key: "isolation_guidance", description: "Isolation/quarantine guidance provided", due_days_from_anchor: 0, required: true, priority: :stat, documentation: [] },
          { key: "clearance_assessment", description: "Clearance assessment for return to activities", due_days_from_anchor: 14, required: true, priority: :routine, documentation: [] }
        ].freeze
      }.freeze
    end
  end
end
