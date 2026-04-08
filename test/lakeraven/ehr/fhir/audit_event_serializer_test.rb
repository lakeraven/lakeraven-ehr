# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::FHIR::AuditEventSerializerTest < ActiveSupport::TestCase
  Serializer = Lakeraven::EHR::FHIR::AuditEventSerializer

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
  end

  def record(overrides = {})
    Lakeraven::EHR::AuditEvent.create!({
      event_type: "rest",
      action: "R",
      outcome: "0",
      tenant_identifier: "tnt_test",
      facility_identifier: "fac_main",
      agent_who_type: "Application",
      agent_who_identifier: "client-uid-123",
      agent_network_address: "10.0.0.1",
      entity_type: "Patient",
      entity_identifier: "pt_01H8X",
      source_observer: "lakeraven-ehr"
    }.merge(overrides))
  end

  test "resourceType is AuditEvent" do
    assert_equal "AuditEvent", Serializer.call(record)[:resourceType]
  end

  test "id is the Rails primary key as a string" do
    r = record
    assert_equal r.id.to_s, Serializer.call(r)[:id]
  end

  test "type block carries the audit-event-type coding" do
    type = Serializer.call(record)[:type]
    assert_equal "http://terminology.hl7.org/CodeSystem/audit-event-type", type[:system]
    assert_equal "rest", type[:code]
    assert_equal "RESTful Operation", type[:display]
  end

  test "action is the CRUDE code" do
    assert_equal "R", Serializer.call(record)[:action]
  end

  test "recorded is ISO8601" do
    r = record(recorded: Time.utc(2026, 4, 8, 12, 0, 0))
    assert_equal "2026-04-08T12:00:00Z", Serializer.call(r)[:recorded]
  end

  test "outcome and outcomeDesc are populated" do
    serialized = Serializer.call(record(outcome: "4"))
    assert_equal "4", serialized[:outcome]
    assert_equal "Minor Failure", serialized[:outcomeDesc]
  end

  test "agent carries the opaque identifier and network address" do
    agent = Serializer.call(record)[:agent].first
    assert_equal "client-uid-123", agent[:who][:identifier][:value]
    assert_equal "10.0.0.1", agent[:network][:address]
    assert agent[:requestor]
  end

  test "agent network block is omitted when no address was recorded" do
    agent = Serializer.call(record(agent_network_address: nil))[:agent].first
    refute agent.key?(:network)
  end

  test "source observer defaults to lakeraven-ehr when not set" do
    r = record(source_observer: nil)
    assert_equal "lakeraven-ehr", Serializer.call(r)[:source][:observer][:display]
  end

  test "entity carries the opaque identifier and type" do
    entity = Serializer.call(record)[:entity].first
    assert_equal "pt_01H8X", entity[:what][:identifier][:value]
    assert_equal "Patient", entity[:type][:code]
  end

  test "entity is omitted when entity_type is nil" do
    r = record(entity_type: nil, entity_identifier: nil)
    refute Serializer.call(r).key?(:entity)
  end
end
