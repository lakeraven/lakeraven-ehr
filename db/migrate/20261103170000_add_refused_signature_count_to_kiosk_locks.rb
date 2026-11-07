# frozen_string_literal: true

# Counts refused signature posts on the tablet lock (#793).
#
# The limit has to live on the lock row. A cookie the browser can drop
# would reset it. The column is a count, not clinical text. No trigger.
class AddRefusedSignatureCountToKioskLocks < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_kiosk_locks, :refused_signature_count, :integer, null: false, default: 0
  end
end
