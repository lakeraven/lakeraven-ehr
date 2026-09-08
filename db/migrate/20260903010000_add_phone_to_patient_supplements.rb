# frozen_string_literal: true

# Contact phone for Patient.telecom. The mapped RPMS RPC surface (ORWPT
# SELECT / ORWPT ID INFO) carries no telecom; until a demographics RPC read
# path lands, deployments supplement the number here and PatientRepository
# hydrates it onto the Patient model at read time.
class AddPhoneToPatientSupplements < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_patient_supplements, :phone, :string
  end
end
