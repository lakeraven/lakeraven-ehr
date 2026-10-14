# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SmartScopesTest < ActiveSupport::TestCase
      # --- permits?: what a single scope string allows -----------------------
      # Pinned as literals rather than derived from ACTIONS, so a change to the
      # table that widens a scope fails here instead of moving both sides of an
      # equality at once.

      test "a read scope permits reading its own type and nothing else" do
        assert SmartScopes.permits?(%w[system/Patient.read], "Patient", :read)
        refute SmartScopes.permits?(%w[system/Patient.read], "Patient", :write)
        refute SmartScopes.permits?(%w[system/Patient.read], "Observation", :read)
      end

      test "a write scope never permits a read" do
        refute SmartScopes.permits?(%w[system/Patient.write], "Patient", :read)
        refute SmartScopes.permits?(%w[system/*.write], "Patient", :read)
        refute SmartScopes.permits?(%w[system/Patient.c], "Patient", :read)
      end

      test "write, c and * each permit a write" do
        assert SmartScopes.permits?(%w[system/Patient.write], "Patient", :write)
        assert SmartScopes.permits?(%w[system/Patient.c], "Patient", :write)
        assert SmartScopes.permits?(%w[system/Patient.*], "Patient", :write)
      end

      test "a type wildcard covers every type for its action only" do
        assert SmartScopes.permits?(%w[system/*.read], "Observation", :read)
        refute SmartScopes.permits?(%w[system/*.read], "Observation", :write)
        assert SmartScopes.permits?(%w[system/*.*], "Observation", :read)
        assert SmartScopes.permits?(%w[system/*.*], "Observation", :write)
      end

      test "an action wildcard covers both actions on its type only" do
        assert SmartScopes.permits?(%w[system/Patient.*], "Patient", :read)
        refute SmartScopes.permits?(%w[system/Patient.*], "Observation", :read)
      end

      test "an unrecognised action permits nothing" do
        refute SmartScopes.permits?(%w[system/Patient.rs], "Patient", :read)
        refute SmartScopes.permits?(%w[system/Patient.rs], "Patient", :write)
      end

      test "a scope only permits within the contexts asked about" do
        refute SmartScopes.permits?(%w[patient/*.read], "Patient", :read, contexts: %w[system])
        assert SmartScopes.permits?(%w[patient/*.read], "Patient", :read)
        refute SmartScopes.permits?(%w[system/*.*], "Patient", :read, contexts: %w[patient user])
      end

      # --- covers?: may a registration be narrowed to a requested scope ------

      test "a registered type wildcard covers a narrower per-type request" do
        assert SmartScopes.covers?(%w[system/*.read], "system/Patient.read")
      end

      test "a registered action wildcard covers a narrower per-action request" do
        assert SmartScopes.covers?(%w[system/Patient.*], "system/Patient.read")
        assert SmartScopes.covers?(%w[system/Patient.*], "system/Patient.write")
      end

      test "a registered full wildcard covers any well-formed system request" do
        assert SmartScopes.covers?(%w[system/*.*], "system/Observation.write")
        assert SmartScopes.covers?(%w[system/*.*], "system/*.read")
      end

      test "a narrower registration never covers a wider request" do
        refute SmartScopes.covers?(%w[system/Patient.read], "system/*.read")
        refute SmartScopes.covers?(%w[system/*.read], "system/*.*")
        refute SmartScopes.covers?(%w[system/Patient.read], "system/Patient.*")
        refute SmartScopes.covers?(%w[system/Patient.*], "system/*.read")
      end

      test "a read registration never covers a write request" do
        refute SmartScopes.covers?(%w[system/*.read], "system/Patient.write")
        refute SmartScopes.covers?(%w[system/*.read], "system/Patient.c")
        refute SmartScopes.covers?(%w[system/*.read], "system/*.write")
      end

      test "a registration for one type never covers another type" do
        refute SmartScopes.covers?(%w[system/Patient.read], "system/Observation.read")
      end

      test "a registration in one context never covers a request in another" do
        refute SmartScopes.covers?(%w[patient/*.read], "system/Patient.read")
        refute SmartScopes.covers?(%w[user/*.*], "system/Patient.read")
      end

      test "a request that permits nothing is covered only by an exact registration" do
        refute SmartScopes.covers?(%w[system/*.*], "system/Patient.rs")
        refute SmartScopes.covers?(%w[system/*.*], "system/not a scope")
        refute SmartScopes.covers?(%w[system/*.*], "system/*")
        refute SmartScopes.covers?(%w[system/*.*], "system/Pat-ient.read")
        refute SmartScopes.covers?(%w[system/*.*], "system/Patient/x.read")
        assert SmartScopes.covers?(%w[system/Patient.rs], "system/Patient.rs")
      end

      test "separate read and write registrations together cover an action wildcard" do
        assert SmartScopes.covers?(%w[system/Patient.read system/Patient.write], "system/Patient.*")
        refute SmartScopes.covers?(%w[system/Patient.read system/Observation.write], "system/Patient.*")
      end

      test "an empty registration covers nothing" do
        refute SmartScopes.covers?([], "system/Patient.read")
        refute SmartScopes.covers?(nil, "system/Patient.read")
      end

      # --- the invariant, exhaustively ---------------------------------------
      # For every registration drawn from a small universe and every requested
      # scope, covers? holds exactly when the requested scope permits nothing
      # the registration does not: sound (never grants beyond registration) and
      # complete (never refuses what the registration already permits).

      UNIVERSE = %w[Patient Observation *].product(%w[read write c * rs]).map { |t, a| "system/#{t}.#{a}" }
      PROBE_TYPES = %w[Patient Observation Encounter].freeze

      test "covers? is exactly 'grants nothing the registration does not'" do
        registrations = [ [] ] + UNIVERSE.map { |s| [ s ] } + UNIVERSE.combination(2).to_a

        registrations.each do |held|
          UNIVERSE.each do |requested|
            within = PROBE_TYPES.product(%i[read write]).all? do |type, access|
              !SmartScopes.permits?([ requested ], type, access) || SmartScopes.permits?(held, type, access)
            end
            permits_something = PROBE_TYPES.product(%i[read write]).any? do |type, access|
              SmartScopes.permits?([ requested ], type, access)
            end
            expected = held.include?(requested) || (permits_something && within)

            assert_equal expected, SmartScopes.covers?(held, requested),
              "covers?(#{held.inspect}, #{requested.inspect})"
          end
        end
      end
    end
  end
end
