# frozen_string_literal: true

module Lakeraven
  module EHR
    module Rpms
      class Repository
        private

        def execute(gateway_class, method, *args, **kwargs)
          value = if kwargs.any?
            gateway_class.public_send(method, *args, **kwargs)
          else
            gateway_class.public_send(method, *args)
          end
          Integrations::Result.success(value)
        rescue RpmsRpc::Client::ConnectionError => e
          Integrations::Result.failure(
            Integrations::Error.new(code: :connection_refused, message: e.message, source: self.class.name)
          )
        rescue RpmsRpc::Client::AuthenticationError => e
          Integrations::Result.failure(
            Integrations::Error.new(code: :authentication_failed, message: e.message, source: self.class.name)
          )
        rescue Timeout::Error => e
          Integrations::Result.failure(
            Integrations::Error.new(code: :timeout, message: e.message, source: self.class.name)
          )
        end

        def build_model(model_class, data, attribute_map:)
          return nil if data.nil?

          attrs = attribute_map.each_with_object({}) do |(model_attr, data_key), hash|
            hash[model_attr] = data[data_key]
          end

          model_class.new(attrs)
        end

        def build_models(model_class, data_list, attribute_map:)
          return [] unless data_list.is_a?(Array)

          data_list.map { |data| build_model(model_class, data, attribute_map: attribute_map) }
        end
      end
    end
  end
end
