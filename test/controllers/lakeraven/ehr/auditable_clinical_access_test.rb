# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "logger"

module Lakeraven
  module EHR
    class AuditableClinicalAccessTest < ActiveSupport::TestCase
      class FakeController < ActionController::Base
        include Lakeraven::EHR::AuditableClinicalAccess

        attr_accessor :current_token

        def initialize(method:, status:, params: {})
          super()
          @fake_method = method
          @fake_status = status
          @fake_params = params
        end

        def request
          @fake_request ||= FakeRequest.new(@fake_method, @fake_params)
        end

        def response
          @fake_response ||= FakeResponse.new(@fake_status)
        end

        def params
          @fake_params
        end

        def fhir_resource_type
          "TestResource"
        end
      end

      class FakeRequest
        attr_reader :method_symbol, :remote_ip, :headers

        def initialize(method, params = {})
          @method_symbol = method
          @remote_ip = "127.0.0.1"
          @headers = {}
        end
      end

      class FakeResponse
        attr_reader :status

        def initialize(status)
          @status = status
        end
      end

      test "GET maps to read action" do
        controller = FakeController.new(method: :get, status: 200)
        assert_equal "R", controller.send(:audit_action)
      end

      test "POST maps to create action" do
        controller = FakeController.new(method: :post, status: 201)
        assert_equal "C", controller.send(:audit_action)
      end

      test "PUT maps to update action" do
        controller = FakeController.new(method: :put, status: 200)
        assert_equal "U", controller.send(:audit_action)
      end

      test "PATCH maps to update action" do
        controller = FakeController.new(method: :patch, status: 200)
        assert_equal "U", controller.send(:audit_action)
      end

      test "DELETE maps to delete action" do
        controller = FakeController.new(method: :delete, status: 204)
        assert_equal "D", controller.send(:audit_action)
      end

      test "unknown method maps to execute action" do
        controller = FakeController.new(method: :head, status: 200)
        assert_equal "E", controller.send(:audit_action)
      end

      test "successful response maps to success outcome" do
        controller = FakeController.new(method: :get, status: 200)
        assert_equal "0", controller.send(:audit_outcome)
      end

      test "client error maps to minor failure outcome" do
        controller = FakeController.new(method: :get, status: 404)
        assert_equal "4", controller.send(:audit_outcome)
      end

      test "server error maps to serious failure outcome" do
        controller = FakeController.new(method: :get, status: 500)
        assert_equal "8", controller.send(:audit_outcome)
      end

      test "sanitized entity identifier hashes raw DFN" do
        controller = FakeController.new(method: :get, status: 200, params: { dfn: "123" })
        refute_equal "123", controller.send(:sanitized_entity_identifier)
        assert_equal VistaRpc::PhiSanitizer.hash_identifier("123"), controller.send(:sanitized_entity_identifier)
      end

      test "audit write errors are sanitized before logging" do
        controller = FakeController.new(method: :get, status: 200, params: { dfn: "12345" })
        controller.current_token = OpenStruct.new(application: OpenStruct.new(uid: "test-app"))

        original_create = AuditEvent.method(:create!)
        AuditEvent.singleton_class.send(:define_method, :create!) do |*args|
          raise StandardError, "Database error for patient SMITH,JOHN with DFN:12345"
        end

        original_logger = Rails.logger
        fake_logger = Logger.new(StringIO.new)
        Rails.logger = fake_logger

        controller.send(:record_audit_event)

        logged = fake_logger.instance_variable_get(:@logdev).dev.string
        refute logged.include?("SMITH,JOHN")
        refute logged.include?("DFN:12345")
        assert logged.include?("[NAME-REDACTED]")
      ensure
        AuditEvent.singleton_class.send(:define_method, :create!, original_create)
        Rails.logger = original_logger
      end
    end
  end
end
