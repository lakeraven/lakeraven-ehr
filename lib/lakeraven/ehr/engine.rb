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
        # `allergy` is the chart entry payload: allergen, comments, symptoms.
        app.config.filter_parameters += %i[username access_code verify_code allergy]
      end

      NO_RPMS_BACKEND = "[lakeraven-ehr] No RPMS backend configured: name a broker in " \
                        "config/rpms.yml (README, \"RPMS backend\"). Sign-in will fail."

      # The live broker client, built once per process from the host app's
      # config/rpms.yml (#539). It runs after the host app's initializers, so a
      # client configured there (or the SPIKE_MOCK_RPC demo mock) wins.
      # Not in the test environment, where test_helper installs the mock client
      # right after boot and the warning would be wrong.
      config.after_initialize do
        Lakeraven::EHR::Engine.configure_rpms_broker!(logger: (Rails.logger unless Rails.env.test?))
      end

      # The host's config/rpms.yml for this environment, or nothing when the
      # host has none.
      def self.rpms_settings
        return {} unless Rails.root.join("config", "rpms.yml").exist?

        Rails.application.config_for(:rpms)
      end

      # broker picks the wire (cia or xwb), host and port say where. No host,
      # no client. The socket opens at sign-on, not here, so the app boots with
      # the broker down. lakeraven-ehr is a front end for RPMS: with no broker
      # named and no client configured, it says so at boot instead of failing
      # at sign-in.
      def self.configure_rpms_broker!(settings = rpms_settings, logger: Rails.logger)
        require "rpms_rpc/core"
        require "rpms_rpc/broker_factory"
        return if RpmsRpc.configuration.client

        if settings[:host].to_s.empty?
          logger&.warn(NO_RPMS_BACKEND)
          return
        end

        # Every signed-in user gets a connection of their own (ADR 0011,
        # RpmsSessions); the web process holds no shared client, so a request
        # outside its user's scope reaches no RPMS at all. The test
        # environment's live suite (LIVE_RPMS=1) signs one shared client on
        # itself and drives gateways directly, so it keeps one; its pooled
        # path is tested on its own.
        factory = -> { RpmsRpc.client_for(settings[:broker], host: settings[:host], port: settings[:port]) }
        if Rails.env.test?
          RpmsRpc.configure { |c| c.client = factory.call }
        else
          RpmsSessions.assert_single_process!
          RpmsSessions.configure!(factory: factory, max_sessions: Integer(settings[:max_sessions] || 64))
        end
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
      # Known edge: a host whose root is a SUBDIRECTORY of an engine checkout
      # (for example a host app vendored under this repository) also matches
      # the guard and would get the engine path next to its install:migrations
      # copies. A host installed the usual way (the gem under the gems
      # directory, the app elsewhere) never matches. Pinned by
      # test/integration/engine_migration_paths_test.rb (host app outside).
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
