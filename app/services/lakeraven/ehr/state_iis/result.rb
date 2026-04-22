# frozen_string_literal: true

module Lakeraven
  module EHR
    module StateIis
      class Result
        attr_reader :data, :message

        def initialize(success:, data: {}, message: nil)
          @success = success
          @data = data || {}
          @message = message
        end

        def success? = @success
        def failure? = !@success

        def record_count
          data[:immunizations]&.length || 0
        end

        def self.success(data: {})
          new(success: true, data: data)
        end

        def self.failure(message:)
          new(success: false, message: message)
        end
      end
    end
  end
end
