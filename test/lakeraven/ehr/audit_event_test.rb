# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::AuditEventTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR::AuditEvent.delete_all
  end

  def valid_attrs(overrides = {})
    {
      event_type: "rest",
      action: "R",
      outcome: "0",
      tenant_identifier: "tnt_test",
      facility_identifier: "fac_main",
      agent_who_type: "Application",
      agent_who_identifier: "client-uid-123",
      entity_type: "Patient",
      entity_identifier: "pt_01H8X"
    }.merge(overrides)
  end

  test "creates with valid attributes" do
    event = Lakeraven::EHR::AuditEvent.create!(valid_attrs)
    assert event.persisted?
  end

  test "recorded defaults to now on create" do
    freeze = Time.utc(2026, 4, 8, 12, 0, 0)
    travel_to(freeze) do
      event = Lakeraven::EHR::AuditEvent.create!(valid_attrs)
      assert_equal freeze, event.recorded
    end
  end

  test "recorded can be supplied explicitly" do
    fixed = Time.utc(2026, 1, 1, 0, 0, 0)
    event = Lakeraven::EHR::AuditEvent.create!(valid_attrs(recorded: fixed))
    assert_equal fixed, event.recorded
  end

  test "validation rejects missing event_type" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(event_type: nil)).valid?
  end

  test "validation rejects unknown event_type" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(event_type: "bogus")).valid?
  end

  test "validation rejects missing action" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(action: nil)).valid?
  end

  test "validation rejects unknown action" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(action: "X")).valid?
  end

  test "validation rejects unknown outcome" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(outcome: "99")).valid?
  end

  test "validation rejects missing tenant_identifier" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(tenant_identifier: nil)).valid?
  end

  test "validation rejects missing agent_who fields" do
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(agent_who_type: nil)).valid?
    refute Lakeraven::EHR::AuditEvent.new(valid_attrs(agent_who_identifier: nil)).valid?
  end

  # -- immutability ----------------------------------------------------------

  test "update raises ActiveRecord::ReadOnlyRecord" do
    event = Lakeraven::EHR::AuditEvent.create!(valid_attrs)
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      event.update!(outcome: "4")
    end
  end

  test "save on a persisted row raises ActiveRecord::ReadOnlyRecord" do
    event = Lakeraven::EHR::AuditEvent.create!(valid_attrs)
    event.outcome = "4"
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.save }
  end

  test "destroy raises ReadOnlyRecord" do
    event = Lakeraven::EHR::AuditEvent.create!(valid_attrs)
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
  end

  test "delete raises ReadOnlyRecord" do
    event = Lakeraven::EHR::AuditEvent.create!(valid_attrs)
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
  end

  # -- scopes ----------------------------------------------------------------

  test "for_tenant filters by tenant_identifier" do
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(tenant_identifier: "tnt_a"))
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(tenant_identifier: "tnt_b"))
    assert_equal 1, Lakeraven::EHR::AuditEvent.for_tenant("tnt_a").count
  end

  test "for_entity filters by type + identifier" do
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(entity_identifier: "pt_one"))
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(entity_identifier: "pt_two"))
    assert_equal 1, Lakeraven::EHR::AuditEvent.for_entity("Patient", "pt_one").count
  end

  test "recent orders by recorded desc" do
    old = Lakeraven::EHR::AuditEvent.create!(valid_attrs(recorded: 1.day.ago))
    new_event = Lakeraven::EHR::AuditEvent.create!(valid_attrs(recorded: 1.hour.ago))
    assert_equal [ new_event.id, old.id ], Lakeraven::EHR::AuditEvent.recent.pluck(:id)
  end

  test "successful scope filters outcome 0" do
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(outcome: "0"))
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(outcome: "4"))
    assert_equal 1, Lakeraven::EHR::AuditEvent.successful.count
  end

  test "failed scope filters outcome != 0" do
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(outcome: "0"))
    Lakeraven::EHR::AuditEvent.create!(valid_attrs(outcome: "8"))
    assert_equal 1, Lakeraven::EHR::AuditEvent.failed.count
  end
end
