# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class NoGemRoleLayerTest < ActiveSupport::TestCase
      ROOT = File.expand_path("../..", __dir__).freeze

      SCAN_ROOTS = %w[app lib config features test].map { |dir| File.join(ROOT, dir) }.freeze

      SKIP_PATH_SEGMENTS = [
        File.join("test", "dummy", "log"),
        File.join("test", "dummy", "tmp")
      ].freeze

      CAPABILITIES_REF = "RpmsRpc::" + "Capabilities"
      USER_ROLES_REF = "RpmsRpc::" + "UserRoles"
      FORBIDDEN = [ CAPABILITIES_REF, USER_ROLES_REF ].freeze

      RPMS_RPC_GEM = "rpms" + "_rpc"
      CAPABILITIES_FILE = "cap" + "abilities"
      USER_ROLES_FILE = "user" + "_roles"
      CAPABILITIES_MOD = "Cap" + "abilities"
      USER_ROLES_MOD = "User" + "Roles"

      CONST_GET_ARG_PATTERNS = [
        /const_get\s*\(\s*:#{CAPABILITIES_MOD}\b/,
        /const_get\s*\(\s*["']#{CAPABILITIES_MOD}["']/,
        /const_get\s*\(\s*:#{USER_ROLES_MOD}\b/,
        /const_get\s*\(\s*["']#{USER_ROLES_MOD}["']/
      ].freeze

      LINE_PATTERNS = (
        [
          /require\s+["']#{RPMS_RPC_GEM}\/#{CAPABILITIES_FILE}["']/,
          /require\s+["']#{RPMS_RPC_GEM}\/#{USER_ROLES_FILE}["']/,
          /require\s*\(\s*["']#{RPMS_RPC_GEM}\/["']\s*["']#{CAPABILITIES_FILE}["']\s*\)/,
          /require\s*\(\s*["']#{RPMS_RPC_GEM}\/["']\s*["']#{USER_ROLES_FILE}["']\s*\)/
        ] + CONST_GET_ARG_PATTERNS
      ).freeze

      test "line matcher flags forbidden gem role layer references and ignores innocent lines" do
        forbidden_samples = [
          "LEGACY = ::RpmsRpc.const_get(:#{CAPABILITIES_MOD})",
          "RpmsRpc.const_get(:#{CAPABILITIES_MOD})",
          %(::RpmsRpc.const_get("#{USER_ROLES_MOD}")),
          %(Object.const_get("RpmsRpc").const_get(:#{CAPABILITIES_MOD})),
          %(require("rpms_rpc/" "capabilities")),
          %(require("rpms_rpc/" "user_roles")),
          %(require 'rpms_rpc/capabilities'),
          %(require 'rpms_rpc/user_roles')
        ]

        forbidden_samples.each do |line|
          assert forbidden_line?(line), "expected forbidden: #{line}"
        end

        assert_not forbidden_line?("RpmsRpc::SecurityKeys.symbolize(raw_keys)")
      end

      test "no references to gem role or capability modules remain in app lib config features or test" do
        hits = []
        this_file = File.expand_path(__FILE__)

        SCAN_ROOTS.each do |root|
          Dir.glob(File.join(root, "**", "*")).each do |path|
            next unless File.file?(path)
            next if path == this_file
            next if SKIP_PATH_SEGMENTS.any? { |segment| path.include?(segment) }

            scan_file_lines(path).each do |line_no, line|
              next unless forbidden_line?(line)

              hits << "#{path.sub("#{ROOT}/", '')}:#{line_no}: #{line.strip}"
            end
          end
        end

        assert_empty hits,
          "remove gem role layer references (issue #638):\n#{hits.join("\n")}"
      end

      def forbidden_line?(line)
        FORBIDDEN.any? { |needle| line.include?(needle) } ||
          LINE_PATTERNS.any? { |pattern| line.match?(pattern) }
      end

      def scan_file_lines(path)
        lines = []
        File.open(path, "rb") do |io|
          io.each_line.with_index(1) do |raw_line, line_no|
            line = raw_line.dup.force_encoding(Encoding::UTF_8)
            next unless line.valid_encoding?

            lines << [ line_no, line ]
          end
        end
        lines
      end
    end
  end
end
