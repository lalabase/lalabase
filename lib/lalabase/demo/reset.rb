# frozen_string_literal: true

module Lalabase
  module Demo
    # The nightly reset of the public demo (DemoResetJob, `bin/rails lalabase:demo:reset`):
    # empties every table that holds what visitors wrote, deletes the stored files, and
    # builds the Nordlicht world again.
    #
    # Refuses unless both latches hold (Demo.resettable?): the flag LALABASE_DEMO and the
    # marker row that only Lalabase::Demo::Setup writes. A self-hoster who sets the flag
    # by mistake loses nothing.
    #
    # Everything is wiped unless KEPT_TABLES names it, so a new table of visitor content
    # is wiped without anybody remembering it. The kept ones belong to the instance: the
    # schema, the queue the job runs in, the admins, the settings with the marker, and
    # the AI credentials and packages the operator configured.
    #
    # One TRUNCATE without CASCADE, in one transaction with the new world: Postgres
    # refuses it when a kept table still references a wiped one (CASCADE would empty
    # the kept table instead, silently), and a world that fails to build leaves the old
    # one in place. The files of kept records survive (StoredFiles), their rich text
    # would not, which the guard in spec/architecture/demo_reset_tables_guard_spec.rb
    # rules out together with the foreign keys.
    #
    # Not Organisation#destroy: it has known blockers (projects with documents) and runs
    # every callback for data that is about to go anyway.
    class Reset
      class Refused < StandardError; end

      KEPT_TABLES = %w[
        schema_migrations ar_internal_metadata
        beusers system_settings
        ai_credentials ai_credential_contracts ai_credential_documents ai_credential_contract_documents
        ai_packages ai_package_tiers
        price_lists price_tiers
        product_knowledge_entries
      ].freeze
      # Solid Queue runs this very job; its tables are the scheduler's, not the visitors'.
      KEPT_PREFIX = 'solid_queue_'

      # AI on, through the instance's system credential: no own key, no package.
      ORGANISATION = { ai_enabled: true, assistant_enabled: true, ai_provider: 'openai' }.freeze

      def self.call(**) = new(**).call

      def self.kept_table?(table) = KEPT_TABLES.include?(table) || table.start_with?(KEPT_PREFIX)

      def self.wiped_tables(connection = ActiveRecord::Base.connection)
        connection.tables.reject { |table| kept_table?(table) }.sort
      end

      def initialize(now: Time.current)
        @now = now
      end

      # @return [Lalabase::Demo::World] the world built afterwards
      def call
        raise Refused, 'Demo mode is off or this instance was never set up as a demo.' unless Demo.resettable?

        # The job, the task and the setup run without a tenant, and the commit fires
        # callbacks of every record of the world (ProjectPermission subscribes its
        # person) outside World#build's own with_tenant.
        ActsAsTenant.without_tenant { reset }
      end

      private

      def reset
        files = nil
        world = ActiveRecord::Base.transaction do
          files = StoredFiles.new(self.class)
          wipe
          files.restore_kept
          reseed
          World.new(locale: Demo::LOCALE, now: @now, organisation: ORGANISATION, embeddings: true,
                    password: PASSWORD).build
        end
        # After the commit: a world that failed to build keeps its files. The
        # embeddings first, so a file that cannot be deleted costs nothing else.
        Embeddings::ActivationBackfill.call(world.organisation)
        files.delete_wiped
        world
      end

      def wipe
        connection = ActiveRecord::Base.connection
        tables = self.class.wiped_tables(connection).map { |table| connection.quote_table_name(table) }
        connection.execute("TRUNCATE #{tables.join(', ')}")
      end

      # The global persona pool hangs on organisations by a foreign key, so it goes
      # with them and comes back from the seed every instance loads. Wrapped, so the
      # seed's constant is not redefined in the worker every night.
      def reseed
        load Rails.root.join('db/seeds/prompt_personas.rb').to_s, true
      end

      # The stored files across a reset. Attachments and blobs live in wiped tables, also
      # those of a kept record (the terms of an AI credential), so those rows are copied
      # aside and written back after the TRUNCATE, and their files stay. A preview or
      # variant of a kept file hangs on the blob, not on the record, and is made again
      # when somebody asks for it.
      #
      # Read under a lock: a blob created between the read and the TRUNCATE would lose
      # its row and keep its file.
      class StoredFiles
        STORAGE_TABLES = %w[active_storage_blobs active_storage_attachments].freeze

        def initialize(reset_class)
          @connection = ActiveRecord::Base.connection
          @connection.execute("LOCK TABLE #{STORAGE_TABLES.join(', ')} IN ACCESS EXCLUSIVE MODE")
          kept = ActiveStorage::Attachment.where(record_type: kept_record_types(reset_class))
          @kept_blob_ids = kept.pluck(:blob_id)
          @wiped = ActiveStorage::Blob.where.not(id: @kept_blob_ids).pluck(:service_name, :key)
          set_aside(kept)
        end

        def restore_kept
          @connection.execute('INSERT INTO active_storage_blobs SELECT * FROM demo_kept_blobs')
          @connection.execute('INSERT INTO active_storage_attachments SELECT * FROM demo_kept_attachments')
        end

        # One file that cannot be deleted does not keep the others.
        def delete_wiped
          @wiped.each do |service_name, key|
            ActiveStorage::Blob.services.fetch(service_name).delete(key)
          rescue StandardError => e
            Rails.logger.warn("[Demo] reset could not delete stored file #{key}: #{e.class}")
          end
        end

        private

        def kept_record_types(reset_class)
          ActiveStorage::Attachment.distinct.pluck(:record_type).select do |type|
            model = type.safe_constantize
            model.respond_to?(:table_name) && reset_class.kept_table?(model.table_name)
          end
        end

        # Temporary tables of this transaction, gone with its commit.
        def set_aside(kept)
          @connection.execute(<<~SQL.squish)
            CREATE TEMPORARY TABLE demo_kept_attachments ON COMMIT DROP AS #{kept.to_sql}
          SQL
          @connection.execute(<<~SQL.squish)
            CREATE TEMPORARY TABLE demo_kept_blobs ON COMMIT DROP AS
            #{ActiveStorage::Blob.where(id: @kept_blob_ids).to_sql}
          SQL
        end
      end
    end
  end
end
