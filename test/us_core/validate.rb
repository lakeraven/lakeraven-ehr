#!/usr/bin/env ruby
# frozen_string_literal: true

# test/us_core/validate.rb -- validate the FHIR the engine serves against US Core 6.1.0.
#
# Usage: test/us_core/validate.rb SAMPLES_DIR
#   SAMPLES_DIR is what test/us_core/fhir_samples_export.rb wrote: manifest.json,
#   metadata.json (the served CapabilityStatement) and the sampled resources.
# Env:
#   US_CORE_VALIDATOR_JAR  path to the HL7 validator_cli.jar (default: validator_cli.jar)
#   GITHUB_STEP_SUMMARY    when set, the results table is appended to it
#
# Each sampled resource is checked against the US Core profile for its type (the
# profile is added to a copy's meta.profile, so one validator run covers every
# type). The verdict follows the CapabilityStatement:
#   * a type it declares a US Core supportedProfile for must validate with no
#     errors, and must have been sampled at all: either failing exits 1;
#   * every other type is reported, errors included, and does not fail the run.
# No validator output, or output that does not cover every file, exits 2: a run
# that did not happen is never a pass.

require "json"
require "fileutils"
require "open3"
require "tmpdir"

US_CORE = "http://hl7.org/fhir/us/core/StructureDefinition"
IG = "hl7.fhir.us.core#6.1.0"

# The US Core 6.1.0 profile a served resource is checked against, or nil
# where US Core has none for the type.
def profile_for(resource)
  type = resource["resourceType"]
  categories = Array(resource["category"]).flat_map { |c| Array(c["coding"]).map { |coding| coding["code"] } }

  case type
  when "Observation"
    if categories.include?("vital-signs") then "#{US_CORE}/us-core-vital-signs"
    elsif categories.include?("laboratory") then "#{US_CORE}/us-core-observation-lab"
    elsif (categories & %w[survey sdoh functional-status disability-status cognitive-status]).any?
      "#{US_CORE}/us-core-observation-screening-assessment"
    else "#{US_CORE}/us-core-observation-clinical-result"
    end
  when "Condition"
    if categories.include?("encounter-diagnosis") then "#{US_CORE}/us-core-condition-encounter-diagnosis"
    else "#{US_CORE}/us-core-condition-problems-health-concerns"
    end
  when "Patient", "Practitioner", "Organization", "Location", "Encounter", "Immunization", "Procedure",
       "ServiceRequest", "AllergyIntolerance", "MedicationRequest", "Medication", "DiagnosticReport",
       "CarePlan", "CareTeam", "Goal", "Coverage", "Device", "DocumentReference", "Provenance",
       "QuestionnaireResponse", "RelatedPerson", "Specimen", "PractitionerRole"
    "#{US_CORE}/us-core-#{type.downcase}"
  end
end

def declared_profiles(metadata)
  metadata.dig("rest", 0, "resource").to_h do |resource|
    [ resource["type"], Array(resource["supportedProfile"]).select { |p| p.start_with?(US_CORE) } ]
  end
end

def issues_by_file(output)
  entries = output["resourceType"] == "Bundle" ? output["entry"].map { |e| e["resource"] } : [ output ]
  entries.to_h do |outcome|
    file = Array(outcome["extension"]).find { |e| e["url"].end_with?("operationoutcome-file") }&.dig("valueString")
    [ File.basename(file.to_s), Array(outcome["issue"]) ]
  end
end

def describe(issue)
  where = Array(issue["expression"] || issue["location"]).first
  text = issue.dig("details", "text") || issue["diagnostics"]
  [ where, text ].compact.join(": ")
end

samples_dir = ARGV.fetch(0) { abort "usage: test/us_core/validate.rb SAMPLES_DIR" }
jar = ENV.fetch("US_CORE_VALIDATOR_JAR", "validator_cli.jar")
abort "validator jar not found: #{jar}" unless File.file?(jar)

manifest = JSON.parse(File.read(File.join(samples_dir, "manifest.json")))
metadata = JSON.parse(File.read(File.join(samples_dir, "metadata.json")))
declared = declared_profiles(metadata)

work = Dir.mktmpdir("us-core-validate")
checked = {} # copy name => { type:, profile:, source: }
unprofiled = Hash.new(0)

manifest.select { |sample| sample["kind"] == "resource" }.each do |sample|
  resource = JSON.parse(File.read(File.join(samples_dir, sample["file"])))
  profile = profile_for(resource)
  unless profile
    unprofiled[sample["type"]] += 1
    next
  end

  resource["meta"] ||= {}
  resource["meta"]["profile"] = (Array(resource["meta"]["profile"]) + [ profile ]).uniq
  name = "#{format('%03d', checked.size + 1)}-#{File.basename(sample['file'])}"
  File.write(File.join(work, name), JSON.generate(resource))
  checked[name] = { type: sample["type"], profile: profile, source: sample["file"] }
end

abort "no US Core-profiled resource in #{samples_dir}" if checked.empty?

output_file = File.join(work, "validation.json")
command = [ "java", "-jar", jar, "-version", "4.0.1", "-ig", IG, *checked.keys.map { |n| File.join(work, n) },
            "-output", output_file ]
log, status = Open3.capture2e(*command)
File.write(File.join(samples_dir, "validator.log"), log)

unless File.file?(output_file)
  warn log.lines.last(40).join
  warn "validator produced no output (exit #{status.exitstatus}); see #{samples_dir}/validator.log"
  exit 2
end

issues = issues_by_file(JSON.parse(File.read(output_file)))
missing = checked.keys - issues.keys
unless missing.empty?
  warn "validator output does not cover: #{missing.join(', ')}"
  exit 2
end
FileUtils.cp(output_file, File.join(samples_dir, "validation.json"))

rows = checked.group_by { |_name, info| [ info[:type], info[:profile] ] }.sort.map do |(type, profile), files|
  found = files.flat_map { |name, _info| issues[name] }
  {
    type: type,
    profile: profile.delete_prefix("#{US_CORE}/"),
    samples: files.size,
    errors: found.select { |issue| %w[error fatal].include?(issue["severity"]) },
    warnings: found.select { |issue| issue["severity"] == "warning" },
    declared: Array(declared[type]).include?(profile)
  }
end

declared_unsampled = declared.flat_map { |type, profiles| profiles.map { |profile| [ type, profile ] } }
                             .reject { |type, profile| checked.values.any? { |i| i[:type] == type && i[:profile] == profile } }

def tally(issues)
  issues.map { |issue| describe(issue) }.tally.map { |text, n| "- #{text}#{" (x#{n})" if n > 1}\n" }.join
end

report = +"### US Core #{IG.split('#').last} validation\n\n"
report << "| Type | Profile | Samples | Errors | Warnings | Declared |\n|---|---|---|---|---|---|\n"
rows.each do |row|
  report << "| #{row[:type]} | #{row[:profile]} | #{row[:samples]} | #{row[:errors].size} | " \
            "#{row[:warnings].size} | #{row[:declared] ? 'yes' : 'no'} |\n"
end
unprofiled.each { |type, count| report << "| #{type} | (none in US Core) | #{count} | - | - | - |\n" }

rows.select { |row| row[:errors].any? }.each do |row|
  report << "\n#### #{row[:type]} errors#{' (declared: this fails the run)' if row[:declared]}\n\n#{tally(row[:errors])}"
end
warned = rows.select { |row| row[:warnings].any? }
if warned.any?
  report << "\n<details><summary>Warnings</summary>\n\n"
  warned.each { |row| report << "#### #{row[:type]}\n\n#{tally(row[:warnings])}\n" }
  report << "</details>\n"
end
declared_unsampled.each do |type, profile|
  report << "\n**#{type} declares #{profile} but no served #{type} was checked against it.**\n"
end

puts report
File.open(ENV["GITHUB_STEP_SUMMARY"], "a") { |f| f.puts(report) } if ENV["GITHUB_STEP_SUMMARY"]

failed = rows.select { |row| row[:declared] && row[:errors].any? }.map { |row| row[:type] } +
         declared_unsampled.map(&:first)
if failed.any?
  warn "US Core errors on declared types: #{failed.join(', ')}"
  exit 1
end

puts "\nEvery declared US Core profile validated with no errors (#{rows.count { |r| r[:declared] }} declared)."
