# frozen_string_literal: true

# In-clinic consent capture (#793). Owner: this engine.
#
# RPMS cannot hold these rows. A signed consent here is the evidence of one
# handover: the exact template body (as a digest), the PNG the patient drew,
# and a later revocation that must be a new row. RPMS has no file for that
# snapshot, and updating the signed row in place would destroy the evidence.
# Template text shipped with the engine is synthetic placeholder wording.
class CreateConsentTemplatesAndSignedConsents < ActiveRecord::Migration[8.1]
  # 500.kilobytes. The model rejects a larger PNG; the check holds the same line.
  MAX_SIGNATURE_BYTES = 500 * 1024

  def change
    create_table :lakeraven_ehr_consent_templates do |t|
      t.string :key, null: false
      t.integer :version, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :consent_scope, null: false
      t.timestamps

      t.index [ :key, :version ], unique: true,
                                  name: "index_lakeraven_ehr_consent_templates_key_version"
    end

    create_table :lakeraven_ehr_signed_consents do |t|
      t.references :consent_template, null: false,
                                      foreign_key: { to_table: :lakeraven_ehr_consent_templates },
                                      index: true
      t.string :patient_dfn, null: false
      t.string :template_key, null: false
      t.integer :template_version, null: false
      t.string :template_body_digest, null: false
      t.string :signer_name
      t.binary :signature_png
      t.datetime :signed_at, null: false
      t.string :witness_duz
      t.string :kind, null: false
      t.string :recorded_by_duz, null: false
      t.bigint :revokes_id
      t.text :revocation_reason
      t.string :handover_token
      t.timestamps

      t.index [ :patient_dfn, :kind ], name: "index_lakeraven_ehr_signed_consents_patient_kind"
      # One handover stores one row. Null tokens are not submissions.
      t.index :handover_token, unique: true, name: "index_lakeraven_ehr_signed_consents_handover_token"
      # A signature is revoked at most once. Null revokes_id (the signatures
      # themselves) may repeat; Postgres treats those nulls as distinct.
      t.index :revokes_id, unique: true, name: "index_lakeraven_ehr_signed_consents_revokes_id"

      # No trigger: a check can require the revocation shape, not freeze every
      # column. Immutability of a saved row is enforced by the model.
      t.check_constraint <<~SQL.squish, name: "signed_consent_row_shape"
        (
          kind = 'signature'
          AND revokes_id IS NULL
          AND witness_duz IS NOT NULL
          AND signature_png IS NOT NULL
          AND octet_length(signature_png) <= #{MAX_SIGNATURE_BYTES}
          AND substring(signature_png FROM 1 FOR 8) = decode('89504e470d0a1a0a', 'hex')
          AND revocation_reason IS NULL
        )
        OR
        (
          kind = 'revocation'
          AND revokes_id IS NOT NULL
          AND revocation_reason IS NOT NULL
          AND signature_png IS NULL
          AND handover_token IS NULL
        )
      SQL
    end
  end
end
