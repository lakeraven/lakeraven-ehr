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
      FORBIDDEN = [CAPABILITIES_REF, USER_ROLES_REF].freeze

      test "no references to gem role or capability modules remain in app lib config or test" do
        hits = []
        this_file = File.expand_path(__FILE__)

        SCAN_ROOTS.each do |root|
          Dir.glob(File.join(root, "**", "*")).each do |path|
            next unless File.file?(path)
            next if path == this_file
            next if SKIP_PATH_SEGMENTS.any? { |segment| path.include?(segment) }

            File.foreach(path).with_index(1) do |line, line_no|
              FORBIDDEN.each do |needle|
                next unless line.include?(needle)

                hits << "#{path.sub("#{ROOT}/", '')}:#{line_no}: #{line.strip}"
              end
            end
          end
        end

        assert_empty hits,
          "remove gem role layer references (issue #638):\n#{hits.join("\n")}"
      end
    end
  end
end
