# frozen_string_literal: true

require "test_helper"

# Engines call the symbolic RpmsRpc API only — never broker RPC names (#644).
class EngineNeverNamesAllergySaveRpcTest < ActiveSupport::TestCase
  APP_ROOT = File.expand_path("../../app", __dir__)

  test "app code does not name ORWDAL32 SAVE ALLERGY" do
    hits = []
    Dir.glob("#{APP_ROOT}/**/*").each do |path|
      next unless File.file?(path)

      File.foreach(path).with_index(1) do |line, lineno|
        hits << "#{path.sub(APP_ROOT + '/', '')}:#{lineno}" if line.include?("ORWDAL32")
      end
    end

    assert_empty hits, "engine app/ must not reference broker RPC names: #{hits.join(', ')}"
  end
end
