# frozen_string_literal: true

require "test_helper"

# The engine's stand-in for RPMS (#1207) is what every other test rests on, so
# its own rules are held here: which answer a call gets, what an unanswered
# call does, what is recorded, and that nothing outlives a reset.
class RpmsStandInTest < ActiveSupport::TestCase
  # A gateway of the test's own: its real code asks rpms-rpc, as an engine
  # gateway does.
  module ThrowawayGateway
    def self.find(dfn, detail: nil) = [ :real, dfn, detail ]
    def self.patient(dfn) = RpmsRpc::Patient.find(dfn)
  end

  test "an answer for named arguments answers that call, and an Integer and its String are one argument" do
    RpmsStandIn.answer(ThrowawayGateway, :find, 7, with: :seven)

    assert_equal :seven, ThrowawayGateway.find(7)
    assert_equal :seven, ThrowawayGateway.find("7")
  end

  test "a call no answer names runs the real code" do
    RpmsStandIn.answer(ThrowawayGateway, :find, 7, with: :seven)

    assert_equal [ :real, 8, :full ], ThrowawayGateway.find(8, detail: :full)
  end

  test "an answer for named arguments wins over one for any, and the newest of either wins" do
    RpmsStandIn.answer(ThrowawayGateway, :find, 7, with: :seven)
    RpmsStandIn.answer(ThrowawayGateway, :find, with: :anyone)
    RpmsStandIn.answer(ThrowawayGateway, :find, with: :anyone_newer)

    assert_equal :seven, ThrowawayGateway.find(7)
    assert_equal :anyone_newer, ThrowawayGateway.find(8)

    RpmsStandIn.answer(ThrowawayGateway, :find, 7, with: :seven_newer)

    assert_equal :seven_newer, ThrowawayGateway.find(7)
  end

  test "a block answers with the call's own arguments, and may raise" do
    RpmsStandIn.answer(ThrowawayGateway, :find) { |dfn, detail: nil| [ :block, dfn, detail ] }

    assert_equal [ :block, 3, :brief ], ThrowawayGateway.find(3, detail: :brief)

    RpmsStandIn.answer(ThrowawayGateway, :find, 9) { raise RpmsRpc::Client::RpcError, "refused" }

    assert_raises(RpmsRpc::Client::RpcError) { ThrowawayGateway.find(9) }
  end

  test "each call of an answered method is kept with its arguments" do
    RpmsStandIn.answer(ThrowawayGateway, :find, 7, with: :seven)

    ThrowawayGateway.find(7)
    ThrowawayGateway.find(8, detail: :full)

    assert_equal [ { args: [ 7 ], kwargs: {} }, { args: [ 8 ], kwargs: { detail: :full } } ],
                 RpmsStandIn.calls(ThrowawayGateway, :find)
  end

  test "an rpms-rpc read the engine makes is answered where the engine makes it, and the gateway's own code runs" do
    RpmsStandIn.answer(RpmsRpc::Patient, :find, 41, with: { dfn: 41, name: "SYNTHETIC,PATIENT" })

    assert_equal({ dfn: 41, name: "SYNTHETIC,PATIENT" }, ThrowawayGateway.patient(41))
    assert_equal "SYNTHETIC,PATIENT", Lakeraven::EHR::PatientGateway.find(41).name
  end

  test "a read nothing answers reaches the connection, which records it and answers nothing on file" do
    before = RpmsRpc.client.received_calls.length

    assert_nil Lakeraven::EHR::PatientGateway.find(987_654)

    sent = RpmsRpc.client.received_calls.drop(before)
    assert_not_empty sent, "the unanswered read never reached the connection"
    assert sent.all? { |call| call.key?(:rpc) }, "an unanswered read is recorded as the RPC it sent"
  end

  test "an answered read is on the connection's record too, so a test can prove RPMS was not asked" do
    before = RpmsRpc.client.received_calls.length

    Lakeraven::EHR::PatientGateway.find(1)

    assert_equal [ "RpmsRpc::Patient.find" ], RpmsRpc.client.received_calls.drop(before).map { |call| call[:answered] }
  end

  test "the stand-in answers on its own connection only: a client the test scopes gets the real code" do
    RpmsStandIn.answer(ThrowawayGateway, :find, 7, with: :seven)
    other = RpmsStandIn::Connection.new

    assert_equal [ :real, 7, nil ], RpmsRpc.with_client(other) { ThrowawayGateway.find(7) }
    assert_nil RpmsRpc.with_client(other) { Lakeraven::EHR::PatientGateway.find(1) },
               "the baseline patient answered on a connection that is not the stand-in's"
    assert_equal :seven, ThrowawayGateway.find(7)
  end

  test "a reset puts every answered method back and starts from the baseline" do
    RpmsStandIn.answer(ThrowawayGateway, :find, with: :anyone)
    RpmsStandIn.answer(RpmsRpc::Patient, :find, 1, with: { dfn: 1, name: "CHANGED,BY A TEST" })
    asked = RpmsRpc.client

    GlobalStoreIsolation.reset!

    assert_equal [ :real, 7, nil ], ThrowawayGateway.find(7)
    assert_empty RpmsStandIn.calls(ThrowawayGateway, :find)
    assert_equal "Anderson,Alice", Lakeraven::EHR::PatientGateway.find(1).name
    assert_not_same asked, RpmsRpc.client, "the reset kept the connection, and with it the calls it recorded"
  end

  test "a bare install has no baseline" do
    RpmsStandIn.install!

    assert_nil Lakeraven::EHR::PatientGateway.find(1)
  end

  test "a user signs on with their own codes, and the sign-on reads answer for that user only" do
    RpmsStandIn.user(77, access: "synthetic", verify: "codes", name: "USER,SYNTHETIC", role: :nurse,
                         keys: [ "ORELSE" ], options: [ "CIAV VUECENTRIC" ], idle_seconds: 600)

    refused = RpmsRpc::Authentication.authenticate(access_code: "synthetic", verify_code: "wrong")
    assert_equal false, refused[:success]
    assert_nil RpmsRpc.client.duz
    assert_nil RpmsRpc::Authentication.held_keys([ "ORELSE" ]), "keys were read with nobody signed on"

    signed_on = RpmsRpc::Authentication.authenticate(access_code: "Synthetic", verify_code: "CODES")
    assert_equal true, signed_on[:success]
    assert_equal 77, signed_on[:duz]
    assert_equal "77", RpmsRpc.client.duz
    assert_equal "nurse", RpmsRpc::Authentication.user_type(77)
    assert_equal 600, RpmsRpc::Authentication.timed_read(77)
    assert_equal [ "ORELSE" ], RpmsRpc::Authentication.held_keys(%w[ORES ORELSE])
    assert_equal [ "CIAV VUECENTRIC" ], RpmsRpc::Authentication.option_access([ "CIAV VUECENTRIC", "ANOTHER OPTION" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.user_type(301) }
  end

  test "the connection gives a recorded reply back verbatim, to rpms-rpc's own parser" do
    connection = RpmsStandIn.connection
    connection.replay("SYNTHETIC RPC", [ "1^FIRST", "2^SECOND" ])
    connection.replay("SYNTHETIC RPC", [ "9^FOR SEVEN" ], first_param: 7)

    assert_equal [ "1^FIRST", "2^SECOND" ], connection.call_rpc("SYNTHETIC RPC", "3").to_a
    assert_equal [ "9^FOR SEVEN" ], connection.call_rpc_lines("SYNTHETIC RPC", "7").to_a
    assert_equal "", connection.call_rpc("ANOTHER RPC").to_s
    assert_equal [ "SYNTHETIC RPC", "SYNTHETIC RPC", "ANOTHER RPC" ], connection.received_calls.map { |call| call[:rpc] }
  end
end
