# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class NoGemRoleLayerTest < ActiveSupport::TestCase
      ROOT = File.expand_path("../..", __dir__).freeze

      SCAN_ROOTS = %w[app lib config test].map { |dir| File.join(ROOT, dir) }.freeze

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
      RPMS_RPC_NS = "Rpms" + "Rpc"

      LINE_PATTERNS = [
        /require\s+["']#{RPMS_RPC_GEM}\/#{CAPABILITIES_FILE}["']/,
        /require\s+["']#{RPMS_RPC_GEM}\/#{USER_ROLES_FILE}["']/,
        /#{RPMS_RPC_NS}::\w*const_get\(\s*:#{CAPABILITIES_MOD}\b/,
        /#{RPMS_RPC_NS}::\w*const_get\(\s*["']#{CAPABILITIES_MOD}["']/,
        /#{RPMS_RPC_NS}::\w*const_get\(\s*:#{USER_ROLES_MOD}\b/,
        /#{RPMS_RPC_NS}::\w*const_get\(\s*["']#{USER_ROLES_MOD}["']/
      ].freeze

      test "no references to gem role or capability modules remain in app lib config or test" do
        hits = []
        this_file = File.expand_path(__FILE__)

        SCAN_ROOTS.each do |root|
          Dir.glob(File.join(root, "**", "*")).each do |path|
            next unless File.file?(path)
            next if path == this_file
            next if SKIP_PATH_SEGMENTS.any? { |segment| path.include?(segment) }

            scan_file_lines(path).each do |line_no, line|
              FORBIDDEN.each do |needle|
                next unless line.include?(needle)

                hits << "#{path.sub("#{ROOT}/", '')}:#{line_no}: #{line.strip}"
              end

              LINE_PATTERNS.each do |pattern|
                next unless line.match?(pattern)

                hits << "#{path.sub("#{ROOT}/", '')}:#{line_no}: #{line.strip}"
              end
            end
          end
        end

        assert_empty hits,
          "remove gem role layer references (issue #638):\n#{hits.join("\n")}"
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
