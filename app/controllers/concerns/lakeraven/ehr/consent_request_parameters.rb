# frozen_string_literal: true

module Lakeraven
  module EHR
    # Cucumber posts through Rack::Test. On Ruby 4, `post path, params: hash`
    # arrives as a nested `params` hash. Integration tests send the fields at
    # the top level. Read either shape. The authenticity token is still checked.
    module ConsentRequestParameters
      extend ActiveSupport::Concern

      private

      def consent_request_param(key)
        return params[key] if param_key?(params, key)

        nested = params[:params]
        nested[key] if param_key?(nested, key)
      end

      def form_authenticity_param
        token = params[request_forgery_protection_token]
        return token if token.present?

        nested = params[:params]
        nested[request_forgery_protection_token] if nested.respond_to?(:[])
      end

      def param_key?(bag, key)
        return false unless bag.respond_to?(:key?)

        bag.key?(key) || bag.key?(key.to_s)
      end
    end
  end
end
