# Solid Queue ships only a full schema template (see the generator's
# lib/generators/solid_queue/install/templates/db/queue_schema.rb), not
# incremental migration files, so db:migrate/db:prepare had nothing to run
# and never actually created these tables. This migration exists so a real,
# trackable migration file lives in db/queue_migrate/ going forward. Every
# table create is guarded so this is safe to run against a database that may
# already have some or all of these tables (e.g. from a manual bootstrap).
class CreateSolidQueueTables < ActiveRecord::Migration[8.1]
  def change
    create_solid_queue_jobs
    create_solid_queue_dependent_tables
    create_solid_queue_processes
    create_solid_queue_pauses
    create_solid_queue_semaphores
    create_solid_queue_recurring_tasks
  end

  private

  def create_solid_queue_jobs
    return if table_exists?(:solid_queue_jobs)

    create_table :solid_queue_jobs do |t|
      t.string :queue_name, null: false
      t.string :class_name, null: false
      t.text :arguments
      t.integer :priority, default: 0, null: false
      t.string :active_job_id
      t.datetime :scheduled_at
      t.datetime :finished_at
      t.string :concurrency_key
      t.timestamps

      t.index :active_job_id
      t.index :class_name
      t.index :finished_at
      t.index [ :queue_name, :finished_at ], name: "index_solid_queue_jobs_for_filtering"
      t.index [ :scheduled_at, :finished_at ], name: "index_solid_queue_jobs_for_alerting"
    end
  end

  def create_solid_queue_dependent_tables
    unless table_exists?(:solid_queue_scheduled_executions)
      create_table :solid_queue_scheduled_executions do |t|
        t.references :job, index: { unique: true }, null: false
        t.string :queue_name, null: false
        t.integer :priority, default: 0, null: false
        t.datetime :scheduled_at, null: false
        t.datetime :created_at, null: false

        t.index [ :scheduled_at, :priority, :job_id ], name: "index_solid_queue_dispatch_all"
      end
      add_foreign_key :solid_queue_scheduled_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end

    unless table_exists?(:solid_queue_ready_executions)
      create_table :solid_queue_ready_executions do |t|
        t.references :job, index: { unique: true }, null: false
        t.string :queue_name, null: false
        t.integer :priority, default: 0, null: false
        t.datetime :created_at, null: false

        t.index [ :priority, :job_id ], name: "index_solid_queue_poll_all"
        t.index [ :queue_name, :priority, :job_id ], name: "index_solid_queue_poll_by_queue"
      end
      add_foreign_key :solid_queue_ready_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end

    unless table_exists?(:solid_queue_claimed_executions)
      create_table :solid_queue_claimed_executions do |t|
        t.references :job, index: { unique: true }, null: false
        t.bigint :process_id
        t.datetime :created_at, null: false

        t.index [ :process_id, :job_id ]
      end
    end

    unless table_exists?(:solid_queue_blocked_executions)
      create_table :solid_queue_blocked_executions do |t|
        t.references :job, index: { unique: true }, null: false
        t.string :queue_name, null: false
        t.integer :priority, default: 0, null: false
        t.string :concurrency_key, null: false
        t.datetime :expires_at, null: false
        t.datetime :created_at, null: false

        t.index [ :concurrency_key, :priority, :job_id ], name: "index_solid_queue_blocked_executions_for_release"
        t.index [ :expires_at, :concurrency_key ], name: "index_solid_queue_blocked_executions_for_maintenance"
      end
      add_foreign_key :solid_queue_blocked_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end

    unless table_exists?(:solid_queue_failed_executions)
      create_table :solid_queue_failed_executions do |t|
        t.references :job, index: { unique: true }, null: false
        t.text :error
        t.datetime :created_at, null: false
      end
      add_foreign_key :solid_queue_failed_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end

    unless table_exists?(:solid_queue_recurring_executions)
      create_table :solid_queue_recurring_executions do |t|
        t.references :job, index: { unique: true }, null: false
        t.string :task_key, null: false
        t.datetime :run_at, null: false
        t.datetime :created_at, null: false

        t.index [ :task_key, :run_at ], unique: true
      end
      add_foreign_key :solid_queue_recurring_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    end
  end

  def create_solid_queue_processes
    return if table_exists?(:solid_queue_processes)

    create_table :solid_queue_processes do |t|
      t.string :kind, null: false
      t.datetime :last_heartbeat_at, null: false
      t.bigint :supervisor_id
      t.integer :pid, null: false
      t.string :hostname
      t.text :metadata
      t.datetime :created_at, null: false
      t.string :name, null: false

      t.index :last_heartbeat_at
      t.index [ :name, :supervisor_id ], unique: true
      t.index :supervisor_id
    end
  end

  def create_solid_queue_pauses
    return if table_exists?(:solid_queue_pauses)

    create_table :solid_queue_pauses do |t|
      t.string :queue_name, null: false
      t.datetime :created_at, null: false

      t.index :queue_name, unique: true
    end
  end

  def create_solid_queue_semaphores
    return if table_exists?(:solid_queue_semaphores)

    create_table :solid_queue_semaphores do |t|
      t.string :key, null: false
      t.integer :value, default: 1, null: false
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :expires_at
      t.index [ :key, :value ]
      t.index :key, unique: true
    end
  end

  def create_solid_queue_recurring_tasks
    return if table_exists?(:solid_queue_recurring_tasks)

    create_table :solid_queue_recurring_tasks do |t|
      t.string :key, null: false
      t.string :schedule, null: false
      t.string :command, limit: 2048
      t.string :class_name
      t.text :arguments
      t.string :queue_name
      t.integer :priority, default: 0
      t.boolean :static, default: true, null: false
      t.text :description
      t.timestamps

      t.index :key, unique: true
      t.index :static
    end
  end
end
