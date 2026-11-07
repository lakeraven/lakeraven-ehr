# frozen_string_literal: true

require "digest"
require "pathname"

# Names the dummy app's test database. database.yml loads this before Rails
# is configured, so the file stays on the stdlib.
module Lakeraven
  module EHR
    module TestDatabaseName
      BASE_NAME = "lakeraven_ehr_test"
      # PostgreSQL identifiers are at most 63 bytes. A 63-byte name is valid;
      # 64 is too long.
      MAX_BYTES = 63
      IDENTIFIER = /\A[a-z][a-z0-9_]*\z/
      DIGITS = /\A\d+\z/
      WORKTREE_HEXITS = 8

      class << self
        def resolve(checkout_root:, env:)
          with_env_number(database_name(checkout_root, env), env)
        end

        private

        def database_name(checkout_root, env)
          explicit = explicit_database(env)
          return explicit if explicit

          checkout_database(checkout_root)
        end

        def explicit_database(env)
          name = stripped(env, "TEST_DATABASE")
          return if name.nil? || name.empty?

          ensure_identifier!(name, "TEST_DATABASE")
          name
        end

        def checkout_database(checkout_root)
          root = Pathname.new(checkout_root)
          return BASE_NAME unless root.join(".git").file?

          hex = Digest::SHA256.hexdigest(File.realpath(checkout_root))
          "#{BASE_NAME}_#{hex[0, WORKTREE_HEXITS]}"
        end

        def with_env_number(name, env)
          number = stripped(env, "TEST_ENV_NUMBER")
          return name if number.nil? || number.empty?
          unless DIGITS.match?(number)
            raise ArgumentError, "TEST_ENV_NUMBER must be digits only"
          end

          suffixed = "#{name}_#{number}"
          ensure_identifier!(suffixed, "TEST_ENV_NUMBER")
          suffixed
        end

        def ensure_identifier!(name, label)
          return if IDENTIFIER.match?(name) && name.bytesize <= MAX_BYTES

          raise ArgumentError, "#{label} must match #{IDENTIFIER.inspect} and be at most #{MAX_BYTES} bytes"
        end

        def stripped(env, key)
          value = env[key]
          return if value.nil?

          value.to_s.strip
        end
      end
    end
  end
end
