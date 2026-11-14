# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientDataServiceCcdsTest < ActiveSupport::TestCase
      setup do
        @service = PatientDataService.new(4)
        @service.define_singleton_method(:phr_available?) { true }
      end

      test "ccds uses the locked Phr API with the patient and both FileMan dates" do
        broker = FakeBroker.new.on("BEHOCIR1 GETCCDS", "")

        RpmsRpc.with_client(broker) do
          assert_equal [], @service.ccds(start_date: Date.new(2000, 1, 1), end_date: Date.new(2026, 12, 31))
        end

        assert_equal [ { rpc: "BEHOCIR1 GETCCDS", params: %w[4 3000101 3261231] } ], broker.calls
      end

      test "ccds keeps the existing default date window" do
        broker = FakeBroker.new.on("BEHOCIR1 GETCCDS", "")

        travel_to Time.zone.local(2026, 11, 14, 12) do
          RpmsRpc.with_client(broker) { assert_equal [], @service.ccds }
        end

        assert_equal [ { rpc: "BEHOCIR1 GETCCDS", params: %w[4 3251114 3261114] } ], broker.calls
      end

      test "ccds returns the API document array unchanged" do
        # This is an API result, not a claimed live CCD wire format. The
        # pinned gem has not verified positive rows on a build with Imaging.
        documents = [ { ien: 42, title: "Synthetic clinical document" } ]

        with_stub(RpmsRpc::Phr, :for_patient, documents) do
          assert_same documents, @service.ccds
        end
      end

      test "an M error is unavailable rather than a successful empty read" do
        broker = FakeBroker.new.raise_with(RpmsRpc::Client::RpcMError.new("MAGSIXG1 synthetic failure"))

        RpmsRpc.with_client(broker) { assert_nil @service.ccds }

        assert_equal [ "BEHOCIR1 GETCCDS" ], broker.calls.map { |call| call[:rpc] }
      end

      test "a successful retry after an M error is an empty array rather than unavailable" do
        unavailable = FakeBroker.new.raise_with(RpmsRpc::Client::RpcMError.new("MAGSIXG1 synthetic failure"))
        available = FakeBroker.new.on("BEHOCIR1 GETCCDS", "")

        RpmsRpc.with_client(unavailable) { assert_nil @service.ccds }
        RpmsRpc.with_client(available) { assert_equal [], @service.ccds }
      end

      test "ccds does not hide a refused RPC a connection error or a programming error" do
        [ RpmsRpc::Client::RpcRefusedError, RpmsRpc::Client::ConnectionError, ArgumentError ].each do |error_class|
          broker = FakeBroker.new.raise_with(error_class.new("synthetic failure"))

          RpmsRpc.with_client(broker) do
            assert_raises(error_class) { @service.ccds }
          end
        end
      end

      test "disabled PHR retains its empty result without calling the broker" do
        service = PatientDataService.new(4)
        broker = FakeBroker.new

        RpmsRpc.with_client(broker) { assert_equal [], service.ccds }

        assert_empty broker.calls
      end
    end
  end
end
