# BPRM twin — parity: lakeraven-ehr (RPC) writes == BPRM v4 (BMW-SQL) writes, at the FileMan layer
# Plan:   docs/BPRM_PARITY_PLAN.md  (lakeraven-ehr#416)
# Tier 1: HTTP-drive lakeraven-ehr on BACKEND=ydb and BACKEND=iris; assert response identity,
#         then assert FileMan read-back == a BPRM golden (BMW.BSF.SP.* invoked directly).
# Oracle: FileMan read-back ($$GET1^DIQ over the touched fields), non-deterministic fields normalized.
# Blocked-on (YDB arm): RPMS Kernel sign-on on YDB — rpms-ops#343.
@bprm_twin @parity
Feature: Reg/sched parity between lakeraven-ehr RPCs and BPRM BMW-SQL
  As the team substituting lakeraven-ehr for BPRM v4's reg/sched
  I want the same clinical action to leave identical FileMan state via either system
  So that lakeraven-ehr is a proven stand-in, not a hopeful one

  Background:
    Given a clean baseline patient fixture
    And the parity oracle reads FileMan back with IEN/DFN/DUZ/timestamps normalized

  # ---- Engine parity: same lakeraven-ehr code, two engines, must agree ----
  @engine
  Scenario Outline: A registration is identical on YDB and IRIS backends
    When I register patient "RAVEN,NORA" born "1990-03-14" sex "F" on backend "<backend>"
    Then the HTTP response is recorded for "<backend>"
    And the FileMan read-back of #2/#9000001 is recorded for "<backend>"

    Examples:
      | backend |
      | ydb     |
      | iris    |

  @engine
  Scenario: The YDB and IRIS registrations are byte-identical after normalization
    Given a registration was run on backend "ydb"
    And the same registration was run on backend "iris"
    Then the two HTTP responses are identical after normalization
    And the two FileMan read-backs of #2/#9000001 are identical after normalization

  # ---- Path parity: lakeraven-ehr RPC write == BPRM BMW-SQL write, same FileMan state ----
  @path
  Scenario: Registering a new patient matches the BPRM BMW-SQL golden
    When I register patient "RAVEN,NOAH" born "1988-11-02" sex "M" via lakeraven-ehr
    And BPRM registers the same patient via BMW.BSF.SP against IRIS
    Then the FileMan read-back of #2/#9000001 matches the BPRM golden

  @path @scheduling
  Scenario: Booking an appointment matches the BPRM BMW-SQL golden
    Given a clinic "GENERAL MEDICINE" with IEN 15
    When I book patient "RAVEN,NOAH" into clinic 15 at "2026-08-20 09:00" via lakeraven-ehr
    And BPRM books the same slot via BMW.BSF.SP (BSDX_APPOINTMENT) against IRIS
    Then the FileMan read-back of #409.* / BSDX appointment matches the BPRM golden

  @path @adt
  Scenario: An admission matches the BPRM BMW-SQL golden at the validated layer
    Given an inpatient ward "MED/SURG" with IEN 3
    When I admit patient "RAVEN,NOAH" to ward 3 at "2026-08-20 14:00" via lakeraven-ehr
    And BPRM admits the same patient via BMW.BSF.SP against IRIS
    Then the FileMan read-back of #405 matches the BPRM golden
    # lakeraven-ehr writes through DGPMV*/^DIE; if BPRM's raw ^DGPM write skipped a movement
    # xref, that is flagged as a BPRM defect, not matched.

  # ---- Error parity: bad input rejected the same way on both paths ----
  @errors
  Scenario: A missing required field is rejected identically by both paths
    When I register a patient with no date of birth via lakeraven-ehr
    And BPRM registers the same patient via BMW.BSF.SP against IRIS
    Then both paths reject the write
    And no #2/#9000001 record is created by either path
