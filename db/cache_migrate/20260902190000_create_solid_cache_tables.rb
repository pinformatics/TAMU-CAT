# Solid Cache ships only a full schema template (see the generator's
# lib/generators/solid_cache/install/templates/db/cache_schema.rb), not
# incremental migration files, so db:migrate/db:prepare had nothing to run
# and never actually created this table -- same issue already solved for
# Solid Queue in db/queue_migrate/20260810180000_create_solid_queue_tables.rb.
# This migration exists so a real, trackable migration file lives in
# db/cache_migrate/ going forward. Guarded so it's safe to run against a
# database that may already have the table (e.g. from a manual bootstrap).
class CreateSolidCacheTables < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:solid_cache_entries)

    create_table :solid_cache_entries do |t|
      t.binary :key, limit: 1024, null: false
      t.binary :value, limit: 536870912, null: false
      t.datetime :created_at, null: false
      t.integer :key_hash, limit: 8, null: false
      t.integer :byte_size, limit: 4, null: false

      t.index :byte_size
      t.index [ :key_hash, :byte_size ]
      t.index :key_hash, unique: true
    end
  end
end
