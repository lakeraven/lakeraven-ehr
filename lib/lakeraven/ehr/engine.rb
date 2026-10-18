# frozen_string_literal: true

# The rpms-rpc entry point loads its whole public API (rpms-rpc #321), so
# the engine requires it once here rather than leaning on a side effect.
require "rpms_rpc"

module Lakeraven
  module EHR
    class Engine < ::Rails::Engine
      isolate_namespace Lakeraven::EHR

      initializer "lakeraven-ehr.doorkeeper_extensions" do |app|
        app.config.to_prepare do
          # Backend-services client bindings live on Doorkeeper::Application;
          # registration-time JWKS transport rules ride along.
          unless Doorkeeper::Application.include?(Lakeraven::EHR::BackendClientRegistration)
            Doorkeeper::Application.include(Lakeraven::EHR::BackendClientRegistration)
          end
        end
      end

      # The VistA ACCESS CODE is a credential, and the sign-on form submits it
      # as `username` — a name no default filter matches, so it was written to
      # the log in cleartext on every sign-on attempt and rode along in every
      # exception report. Filter the field names this engine actually uses for
      # credentials, in the HOST app's config, since that is where request
      # logging reads them from.
      initializer "lakeraven-ehr.filter_credentials" do |app|
        app.config.filter_parameters += %i[username access_code verify_code]
      end

      initializer "lakeraven-ehr.inflections" do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym "EHR"
          inflect.acronym "FHIR"
        end
      end

      # The dummy app lives inside this engine and never copies migrations via
      # `lakeraven_ehr:install:migrations`, so schema:load must see db/migrate
      # here. A host app receives its own copies under new timestamps;
      # appending this path there would run each migration twice. Append only
      # when the app root is a directory inside the engine root.
      #
      # Repo-root bin/rails sets ENGINE_ROOT and Active Record appends that
      # same directory again in db:load_config. Collapse paths that expand or
      # realpath to one directory so Dir[] does not load each file twice.
      initializer "lakeraven-ehr.append_migrations" do |app|
        engine_root = File.realpath(root)
        app_root = File.realpath(app.root)
        next unless app_root.start_with?("#{engine_root}#{File::SEPARATOR}")

        canonical_path = lambda do |path|
          expanded = File.expand_path(path.to_s)
          File.directory?(expanded) ? File.realpath(expanded) : expanded
        end

        migrate_paths = app.config.paths["db/migrate"]
        seen = migrate_paths.to_a.map { |path| canonical_path.call(path) }
        config.paths["db/migrate"].expanded.each do |expanded_path|
          canonical = canonical_path.call(expanded_path)
          next if seen.include?(canonical)

          migrate_paths << expanded_path
          seen << canonical
        end

        next unless defined?(Rake::Task)

        %w[ db:load_config app:db:load_config ].each do |task_name|
          load_config = Rake.application.lookup(task_name, Rake::Scope::EMPTY)
          next unless load_config

          load_config.enhance do
            paths = ActiveRecord::Tasks::DatabaseTasks.migrations_paths
            deduped = paths.uniq { |path| canonical_path.call(path) }
            ActiveRecord::Tasks::DatabaseTasks.migrations_paths = deduped
            ActiveRecord::Migrator.migrations_paths = deduped
          end
        end
      end
    end
  end
end
