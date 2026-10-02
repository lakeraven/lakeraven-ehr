# frozen_string_literal: true

# Exercises bin/bprm_inventory (lakeraven-ehr#565) against a synthetic module
# tree: no Rails, no zip, no real source. Deliberately does not require
# test_helper, which boots the dummy app; the script needs only the stdlib.

require "minitest/autorun"
require "fileutils"
require "tmpdir"

load File.expand_path("../bin/bprm_inventory", __dir__)

class BprmInventoryTest < Minitest::Test
  FAKE_SHA = "f" * 64

  def setup
    @dir = Dir.mktmpdir("bprm_inventory_test")
    @modules = File.join(@dir, "Modules")
    @manifest = File.join(@dir, "manifest.yml")
    write_tree
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_output_is_byte_identical_across_runs
    first = generate
    second = generate
    assert_equal first, second
    assert first.end_with?("\n")
    refute_includes first, "\r"
    refute_includes first, @dir, "a temp path leaked into the output"
  end

  def test_header_names_the_source_and_the_manifest
    header = generate.lines.grep(/\A#/)
    assert_includes header, "# source: demo.zip sha256 #{FAKE_SHA}\n"
    assert_includes header, "# manifest: manifest.yml sha256 #{Digest::SHA256.file(@manifest).hexdigest}\n"
    assert_includes header, "# bmw tables referenced in source but absent from the manifest " \
                            "(left out of bmw_tables): BMW.NOT_IN_MANIFEST\n"
  end

  def test_rows_describe_the_synthetic_features
    rows = generate.lines.reject { |line| line.start_with?("#") }.map { |line| line.chomp.split("\t", -1) }
    assert_equal BprmInventory::COLUMNS, rows[0]
    assert_equal [ "Demo", "(root)", "", "", "", "", "", "", "", "", "", "1" ], rows[1]
    assert_equal [ "Demo", "Alpha", "/alpha;/alpha/{Id}", "AlphaPage.razor", "Core/AddAlphaCommandHandler.cs", "",
                   "Shared/AddAlphaCommandValidator.cs", "CanAlpha", "!AGZVIEWONLY;AGZMENU;AGZMGR",
                   "BMW.ALPHA_TABLE;BMW.VA_PATIENT", "BMW_BSF_SP.AG_SetAlphaQ", "3" ], rows[2]
    assert_equal [ "Demo", "Beta", "", "", "", "App/BetaQueryHandler.cs;Core/BetaQueryHandler.cs", "", "", "",
                   "BMW.ALPHA_TABLE", "", "2" ], rows[3]
    assert_equal 4, rows.size
  end

  def test_check_skips_when_the_zip_is_missing
    status = nil
    out, = capture_io { status = BprmInventory.main([ File.join(@dir, "absent.zip"), @manifest, "--check" ]) }
    assert_equal 0, status
    assert_match(/skip, source zip not present/, out)
  end

  def test_manifest_pin_must_match_the_source
    error = assert_raises(SystemExit) do
      capture_io { BprmInventory.generate(modules_dir: @modules, manifest_path: @manifest, source_name: "demo.zip", source_sha: "0" * 64) }
    end
    assert_equal 1, error.status
  end

  private

  def generate
    BprmInventory.generate(modules_dir: @modules, manifest_path: @manifest, source_name: "demo.zip", source_sha: FAKE_SHA)
  end

  def write_tree
    put "Demo/Demo.App/Features/Alpha/AlphaPage.razor", <<~RAZOR
      ﻿@page "/alpha"
      @page "/alpha/{Id}"
      @attribute [Authorize(Policy = Policies.CanAlpha)]
      @* @attribute [Authorize(Policy = Policies.Commented)] *@
      <h1>Alpha</h1>
    RAZOR
    put "Demo/Demo.Core/Features/Alpha/AddAlphaCommandHandler.cs", <<~CS
      // select * from BMW.COMMENTED_OUT
      private const string Sql = "INSERT INTO bmw.alpha_table (X) VALUES (?)";
      private const string Patient = "SELECT 1 FROM BMW.BMW.VA_PATIENT";
      private const string Proc = "call BMW_BSF_SP.AG_SetAlphaQ(?)";
      private const string Url = "http://example.test/not-a-comment"; // BMW.NOT_IN_MANIFEST
    CS
    put "Demo/Demo.Shared/Features/Alpha/AddAlphaCommandValidator.cs", "public class AddAlphaCommandValidator {}\n"
    put "Demo/Demo.Core/Features/Beta/BetaQueryHandler.cs", "string q = \"SELECT X FROM BMW.ALPHA_TABLE\";\n"
    put "Demo/Demo.App/Features/Beta/BetaQueryHandler.cs", "string q = \"SELECT X FROM BMW.NOT_IN_MANIFEST\";\n"
    put "Demo/Demo.Shared/Policies.cs", policies_source
    put "Demo/Demo.Core.Tests/Features/Alpha/AlphaPage.razor", "@page \"/ignored\"\n"
    File.write(@manifest, manifest_source)
  end

  def policies_source
    <<~CS
      public static class Policies
      {
          public const string CanAlpha = "CanAlpha";
          public const string CanBeta = "CanBetaValue";
          public static AuthorizationPolicy CanAlphaPolicy() => new AuthorizationPolicyBuilder().RequireAuthenticatedUser()
              .RequireMenu("AGMENU")
              .Requirekey("AGZMGR", "AGZMENU").DenyKey("AGZVIEWONLY")
              .Build();
          public static AuthorizationPolicy CanBetaValuePolicy() => new AuthorizationPolicyBuilder()
              .Requirekey("SDZSUP")
              .Build();
      }
    CS
  end

  def manifest_source
    <<~YAML
      source:
        artifact: demo.zip
        sha256: #{FAKE_SHA}
      sql_surface:
        tables:
        - name: BMW.ALPHA_TABLE
          ops: [select, insert]
        - name: BMW.VA_PATIENT
          ops: [select]
    YAML
  end

  def put(relative_path, text)
    path = File.join(@modules, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
end
