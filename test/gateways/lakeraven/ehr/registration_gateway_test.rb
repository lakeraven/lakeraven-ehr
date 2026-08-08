# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/client"

# BPRM twin — registration group gateway tests (scenarios #1, #2, #3, #4).
# The gateway logic (payload encoding, response parsing, success/rejection/
# unavailable branching) is exercised against a scripted FakeBroker; no live
# RPMS is required. The Cucumber features stay red pending rpms-ops#366.
module Lakeraven
  module EHR
    class RegistrationGatewayTest < ActiveSupport::TestCase
      include BrokerStubbing

      # --- #1 Register -----------------------------------------------------

      test "register succeeds and returns the new DFN and name" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "1^123^")
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,NORA", sex: "F", date_of_birth: "1992-03-11",
                                                ssn: "555-01-2345", tribe: "Yakama Nation", community: "Toppenish")

          assert result[:success]
          assert_equal 201, result[:status]
          assert_equal 123, result[:dfn]
          assert_equal "RAVEN,NORA", result[:name]
        end
      end

      test "register encodes name, sex, FileMan DOB, ssn and AG items in field order" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "1^123^")
        use_broker(broker) do
          RegistrationGateway.register(name: "RAVEN,NORA", sex: "F", date_of_birth: "1992-03-11",
                                       ssn: "555-01-2345", tribe: "Yakama Nation",
                                       community: "Toppenish", classification: "Indian/Alaska Native",
                                       eligibility: "Direct")

          payload = broker.last_call[:params].first
          assert_equal "RAVEN,NORA^F^2920311^555-01-2345^Yakama Nation^Toppenish^Indian/Alaska Native^Direct", payload
        end
      end

      test "register rejects a duplicate SSN as 422 with the M-side message" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "0^Duplicate SSN already on file")
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,DUP", sex: "F", date_of_birth: "1985-06-01", ssn: "555-01-2345")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_match(/SSN/, result[:error])
        end
      end

      test "register surfaces a broker-unreachable condition as 503, not a data error" do
        broker = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("connection refused"))
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,NORA", sex: "F", date_of_birth: "1992-03-11", ssn: "555-01-2345")

          refute result[:success]
          assert_equal 503, result[:status]
          assert_equal "Registration service unavailable", result[:error]
        end
      end

      test "register still creates the chart but returns incomplete-registration warnings" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "1^124^COMMUNITY;ELIGIBILITY")
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,NORA", sex: "F", date_of_birth: "1992-03-11", ssn: "555-01-9999")

          assert result[:success]
          assert_includes result[:warnings], "COMMUNITY"
        end
      end

      test "register rejects a blank name without calling the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = RegistrationGateway.register(sex: "F")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "register rejects a caret in a free-text field with 422 without calling the broker" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "1^123^")
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,NORA", sex: "F", date_of_birth: "1992-03-11",
                                                ssn: "555-01-2345", tribe: "Yakama^Nation")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_match(/tribe/, result[:error])
          assert_empty broker.calls, "a caret-bearing field must never be caret-joined into an RPC payload"
        end
      end

      test "register rejects a newline in a free-text field with 422 without calling the broker" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "1^123^")
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,NORA", sex: "F", date_of_birth: "1992-03-11",
                                                ssn: "555-01-2345", community: "Toppenish\nWA")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "register with an unparseable date of birth is rejected with 422, not a raised 500" do
        broker = FakeBroker.new.on("BHDPTRPC REGISTER", "1^123^")
        use_broker(broker) do
          result = RegistrationGateway.register(name: "RAVEN,NORA", sex: "F",
                                                date_of_birth: "not-a-date", ssn: "555-01-2345")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      # --- #2 Edit demographics -------------------------------------------

      test "update succeeds and echoes the changed fields" do
        broker = FakeBroker.new.on("BHDPTRPC UPDATE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.update(42, name: "RAVEN,NORAH")

          assert result[:success]
          assert_equal 200, result[:status]
          assert_equal 42, result[:dfn]
          assert_equal({ name: "RAVEN,NORAH" }, result[:updated])
        end
      end

      test "update encodes DFN plus field=value pairs and FileMan-converts a date of death" do
        broker = FakeBroker.new.on("BHDPTRPC UPDATE", "1^")
        use_broker(broker) do
          RegistrationGateway.update(42, date_of_death: "2026-07-20")

          dfn, payload = broker.last_call[:params]
          assert_equal "42", dfn
          assert_equal "date_of_death=3260720", payload
        end
      end

      test "update rejects an unknown field write with the broker message" do
        broker = FakeBroker.new.on("BHDPTRPC UPDATE", "0^Field not editable")
        use_broker(broker) do
          result = RegistrationGateway.update(42, mbi: "1EG4-TE5-MK73")

          refute result[:success]
          assert_equal 422, result[:status]
        end
      end

      test "update rejects an invalid dfn without calling the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = RegistrationGateway.update(0, name: "X")

          refute result[:success]
          assert_empty broker.calls
        end
      end

      test "update rejects a caret-bearing value with 422 without calling the broker" do
        broker = FakeBroker.new.on("BHDPTRPC UPDATE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.update(42, name: "RAVEN^NORAH")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "update with an unparseable date of death is rejected with 422, not a raised 500" do
        broker = FakeBroker.new.on("BHDPTRPC UPDATE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.update(42, date_of_death: "not-a-date")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      # --- #4 Search + face sheet -----------------------------------------

      test "search parses broker rows into patient hashes" do
        broker = FakeBroker.new.on("BHDPTRPC LOOKUP",
                                   [ "42^RAVEN,NORA^2920311^F", "43^RAVEN,NOAH^2880104^M" ])
        use_broker(broker) do
          result = RegistrationGateway.search("RAVEN")

          assert result[:success]
          assert_equal 2, result[:patients].length
          assert_equal [ "RAVEN,NORA", "RAVEN,NOAH" ], result[:patients].map { |p| p[:name] }
        end
      end

      test "search narrows the match by date of birth" do
        broker = FakeBroker.new.on("BHDPTRPC LOOKUP",
                                   [ "42^RAVEN,NORA^2920311^F", "43^RAVEN,NOAH^2880104^M" ])
        use_broker(broker) do
          result = RegistrationGateway.search("RAVEN", dob: "1992-03-11")

          assert_equal 1, result[:patients].length
          assert_equal "RAVEN,NORA", result[:patients].first[:name]
        end
      end

      test "face sheet returns name, community and tribe" do
        broker = FakeBroker.new.on("BHDPTRPC FACESHEET", "RAVEN,NORA^Toppenish^Yakama Nation^")
        use_broker(broker) do
          result = RegistrationGateway.face_sheet(42)

          assert result[:success]
          assert_equal "Toppenish", result[:face_sheet][:community]
          assert_equal "Yakama Nation", result[:face_sheet][:tribe]
        end
      end

      test "face sheet surfaces registration errors and warnings" do
        broker = FakeBroker.new.on("BHDPTRPC FACESHEET", "RAVEN,NORA^Toppenish^Yakama Nation^ELIGIBILITY")
        use_broker(broker) do
          result = RegistrationGateway.face_sheet(42)

          assert_includes result[:warnings], "ELIGIBILITY"
        end
      end

      test "face sheet of an unknown DFN returns 404" do
        broker = FakeBroker.new.on("BHDPTRPC FACESHEET", "")
        use_broker(broker) do
          result = RegistrationGateway.face_sheet(99999)

          refute result[:success]
          assert_equal 404, result[:status]
        end
      end

      # --- #3 Eligibility + insurance -------------------------------------

      test "insurances lists a patient's coverage with in-use flags" do
        broker = FakeBroker.new.on("BHDPTRPC INSLIST",
                                   [ "1^Medicaid (WA)^WA55501234^Medicaid^1", "2^Contract Health^CHS-2026-88^Tribal^1" ])
        use_broker(broker) do
          result = RegistrationGateway.insurances(42)

          assert_equal 2, result[:insurances].length
          medicaid = result[:insurances].find { |i| i[:payer] == "Medicaid (WA)" }
          assert medicaid[:in_use]
        end
      end

      test "update_insurance files a new policy number and returns success" do
        broker = FakeBroker.new.on("BHDPTRPC INSEDIT", "1^")
        use_broker(broker) do
          result = RegistrationGateway.update_insurance(42, 1, policy_number: "WA55509999")

          assert result[:success]
          assert_equal "WA55509999", result[:policy_number]
          assert_equal "42^1^WA55509999", broker.last_call[:params].last
        end
      end

      test "delete_insurance removes a not-in-use policy through the FileMan cascade path" do
        broker = FakeBroker.new
                           .on("BHDPTRPC INSLIST", [ "2^Contract Health^CHS-2026-88^Tribal^0" ])
                           .on("BHDPTRPC INSDELETE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.delete_insurance(42, 2)

          assert result[:success]
          assert_equal :fileman, result[:cascade]
          assert_equal 1, broker.calls_for("BHDPTRPC INSDELETE").length
        end
      end

      test "deleting an in-use insurance is blocked with 409 before any delete call" do
        broker = FakeBroker.new
                           .on("BHDPTRPC INSLIST", [ "1^Medicaid (WA)^WA55501234^Medicaid^1" ])
                           .on("BHDPTRPC INSDELETE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.delete_insurance(42, 1)

          refute result[:success]
          assert_equal 409, result[:status]
          assert_match(/in use/i, result[:error])
          assert_empty broker.calls_for("BHDPTRPC INSDELETE")
        end
      end

      test "update_insurance rejects a policy number containing the caret delimiter" do
        broker = FakeBroker.new.on("BHDPTRPC INSEDIT", "1^")
        use_broker(broker) do
          result = RegistrationGateway.update_insurance(42, 1, policy_number: "WA555^09999")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      # The cascade delete must fail CLOSED: when the in-use check cannot
      # POSITIVELY confirm the policy is not in use (read failure, malformed
      # row, absent target), the delete is refused with 409 — it must never
      # proceed on an unconfirmed guard.

      test "delete_insurance refuses with 409 when the insurance list cannot be read" do
        broker = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("service unavailable"))
        use_broker(broker) do
          result = RegistrationGateway.delete_insurance(42, 2)

          refute result[:success]
          assert_equal 409, result[:status]
          assert_match(/cannot confirm/i, result[:error])
          assert_empty broker.calls_for("BHDPTRPC INSDELETE")
        end
      end

      test "delete_insurance refuses with 409 when the INSLIST row is malformed" do
        broker = FakeBroker.new
                           .on("BHDPTRPC INSLIST", [ "^^^^" ])
                           .on("BHDPTRPC INSDELETE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.delete_insurance(42, 2)

          refute result[:success]
          assert_equal 409, result[:status]
          assert_empty broker.calls_for("BHDPTRPC INSDELETE")
        end
      end

      test "delete_insurance refuses with 409 when the policy is absent from the listing" do
        broker = FakeBroker.new
                           .on("BHDPTRPC INSLIST", [ "1^Medicaid (WA)^WA55501234^Medicaid^0" ])
                           .on("BHDPTRPC INSDELETE", "1^")
        use_broker(broker) do
          result = RegistrationGateway.delete_insurance(42, 2)

          refute result[:success]
          assert_equal 409, result[:status]
          assert_empty broker.calls_for("BHDPTRPC INSDELETE")
        end
      end
    end
  end
end
