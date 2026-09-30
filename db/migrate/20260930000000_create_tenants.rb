# frozen_string_literal: true

class CreateTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_tenants do |t|
      t.string :name
    end

    create_table :lakeraven_ehr_approved_instances do |t|
      t.bigint :tenant_id
      t.string :instance_identifier
      t.string :division_ien
    end
  end
end
