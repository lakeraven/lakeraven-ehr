# frozen_string_literal: true

require "test_helper"
require "socket"
require "rpms_rpc/cia_client"

# CIA sign-on resolves the signed-on user's DUZ (lakeraven-ehr#540).
#
# The rpms-rpc the engine pinned before (f514068) signed on over CIA but read
# the DUZ with CIANBRPC GETVAR, which can never return it, so every sign-on
# failed with "CIA sign-on resolved no DUZ" and no gateway ran as a user.
# rpms-rpc#251 and its follow-ups read it the way VueCentric does, with
# CIAVCXUS VIMINFO after CIANBRPC AUTH. This drives the pinned gem's
# CiaClient over a real socket, through its public connect and
# authenticate, against a broker that answers each frame with the reply a
# live CIA broker gave (bcer-9.0 YottaDB, as recorded in rpms-rpc's
# cia_client_test.rb), with synthetic identity values.
class CiaSignonDuzTest < ActiveSupport::TestCase
  EOD = RpmsRpc::Client::EOD

  # One reply per client frame, in order. Byte 1 echoes the frame's sequence
  # number (connect is frame 1); "\x00" acknowledges it.
  REPLIES = [
    "1\x00\r\n",
    # CIANBRPC AUTH: status 0, then UID^netname^sitename, then the greeting.
    # It carries no DUZ.
    "2\x000\r\n7^DEMO.EXAMPLE.ORG^DEMO CLINIC\r\n\r\nGood evening USER,DEMO\r\n",
    # CIAVCXUS VIMINFO: DUZ^name^timeouts^compose^design.
    "3\x0063^USER,DEMO^1800;1800;60^0^0",
    # CIANBRPC DIVGET: the chosen division, then ien^name^station.
    "4\x007819\r7819^DEMO IHS CLINIC^8904\r"
  ].freeze

  setup do
    @server = TCPServer.new("127.0.0.1", 0)
    @frames = Queue.new
    @broker = Thread.new { serve(@server.accept) }
  end

  teardown do
    @broker&.kill
    @server&.close
  end

  test "CIA sign-on returns the DUZ the broker reports for the signed-on user" do
    client = RpmsRpc::CiaClient.new
    client.connect("127.0.0.1", @server.addr[1])

    result = client.authenticate("SYN123", "SYN123!!")

    assert result[:success]
    assert_equal 63, result[:duz]
    assert_equal "63", client.duz
    sent = Array.new(@frames.size) { @frames.pop }
    assert(sent.any? { |frame| frame.include?("CIAVCXUS VIMINFO") }, "the DUZ is read with CIAVCXUS VIMINFO")
    refute(sent.any? { |frame| frame.include?("GETVAR") }, "GETVAR cannot return the sign-on DUZ")
  end

  private

  def serve(socket)
    REPLIES.each do |reply|
      @frames << socket.readpartial(65_536)
      socket.write(reply.b + EOD)
    end
  rescue IOError, Errno::ECONNRESET
    nil
  ensure
    socket.close
  end
end
