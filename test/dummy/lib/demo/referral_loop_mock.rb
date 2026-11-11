# frozen_string_literal: true

module Demo
  # MOCK of the steps in the referral loop (#993) that are not built yet:
  #
  #   * the held-for-review Communication store (#988)
  #   * the coordinator's review queue: confirm, reject (#989, #1000)
  #   * the write-back to the RPMS referral (#990, through the BMC RCIS calls
  #     lakeraven/rpms-rpc#722 has to prove live)
  #   * the send to Corvid (#998; Corvid is frozen until after the pilot)
  #
  # PROTOTYPE, not for merge. Everything here lives in memory for one run and
  # is replaced by the real slices as they land. Synthetic data only.
  class ReferralLoopMock
    Held = Struct.new(:id, :communication, :status, :ai_generated, :reviewed_by, :reviewed_at,
      keyword_init: true)

    attr_reader :queue, :rpms_writes, :corvid_payloads

    def initialize
      @queue = []
      @rpms_writes = []
      @corvid_payloads = []
    end

    # #988: the EHR stores the Communication as in-progress and queues it.
    # Nothing reaches RPMS or Corvid at this step.
    def hold(communication, ai_generated:)
      item = Held.new(id: "held-#{@queue.size + 1}", communication: communication,
        status: "in-progress", ai_generated: ai_generated)
      @queue << item
      item
    end

    def pending
      @queue.select { |i| i.status == "in-progress" }
    end

    # #989: a coordinator confirms it. Who and when are recorded.
    def confirm(item, reviewer:)
      item.status = "completed"
      item.reviewed_by = reviewer
      item.reviewed_at = Time.current
      item
    end

    # #990: the confirmed outcome as the writes the RPMS referral would take.
    # The real path goes through the outbox (#997) and is idempotent; here the
    # mock broker's referral row is simply re-seeded so the real FHIR read-back
    # afterwards reads it from "RPMS".
    def write_back_to_rpms(item, referral_row)
      outcome = outcome_of(item.communication)
      writes = [
        { field: "APPOINTMENT DATE", value: outcome[:appointment_on] },
        { field: "SCHEDULING NOTES (1301)",
          value: "Outreach follow-up confirmed by #{item.reviewed_by}: #{outcome[:summary]}" }
      ]
      @rpms_writes.concat(writes)

      updated = referral_row.merge(appointment_date: outcome[:appointment_on], scheduling_notes: writes.last[:value])
      RpmsRpc.client.seed_keyed_collection(:referral_search, referral_row[:patient_dfn].to_s, [ updated ])
      updated
    end

    # #998: what Corvid's referral fulfilment API would receive.
    def corvid_payload(item, referral_row)
      outcome = outcome_of(item.communication)
      payload = {
        referral: referral_row[:referral_number], event: "patient_contacted",
        appointment_on: outcome[:appointment_on], confirmed_by: item.reviewed_by,
        source: "outside app (AI-generated, human-confirmed)"
      }
      @corvid_payloads << payload
      payload
    end

    def outcome_of(communication)
      ext = Array(communication[:extension]).to_h { |e| [ e[:url].split("#").last, e.values.last ] }
      { reached: ext["reached"], appointment_on: ext["appointmentDate"],
        barriers: ext["barriers"], summary: communication.dig(:payload, 0, :contentString) }
    end
  end
end
