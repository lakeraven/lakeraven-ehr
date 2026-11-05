# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ClientJwksTest < ActiveSupport::TestCase
      PROXY_KEYS = %w[http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY].freeze

      setup do
        @previous_resolver = ClientJwks.resolver
        Rails.cache.clear
      end

      teardown do
        ClientJwks.resolver = @previous_resolver
        Rails.cache.clear
      end

      test "jwks fetch dials the vetted address even when HTTPS_PROXY is set" do
        stub_resolver("client.example.test" => [ "203.0.113.10" ])

        dialed = with_proxy_env do
          capture_dials do
            assert_nil ClientJwks.fetch("https://client.example.test/jwks.json")
          end
        end

        assert_equal [ [ "203.0.113.10", 443 ] ], dialed
      end

      test "a private JWKS address is not dialed, even through a proxy" do
        stub_resolver("internal.example.test" => [ "10.0.0.5" ])

        dialed = with_proxy_env do
          capture_dials do
            assert_nil ClientJwks.fetch("https://internal.example.test/jwks.json")
          end
        end

        assert_empty dialed
      end

      test "a JWKS with no Cache-Control is cached for the TTL" do
        assert_equal 1, fetches_of_a_jwks_sent_with(nil)
      end

      test "a JWKS sent with no-store is fetched again every time" do
        assert_equal 2, fetches_of_a_jwks_sent_with("no-store")
      end

      test "a JWKS sent with no-cache or max-age=0 is fetched again every time" do
        assert_equal 2, fetches_of_a_jwks_sent_with("no-cache")
        assert_equal 2, fetches_of_a_jwks_sent_with("public, max-age=0")
      end

      test "a short max-age ends the cached copy when it says" do
        assert_equal 1, fetches_of_a_jwks_sent_with("max-age=60")
        assert_equal 2, fetches_of_a_jwks_sent_with("max-age=60", after: 61.seconds)
      end

      test "a long max-age cannot stretch the cached copy past the TTL" do
        assert_equal 2, fetches_of_a_jwks_sent_with("max-age=86400", after: ClientJwks::CACHE_TTL + 1.second)
      end

      test "restoring the snapshotted resolver removes a scenario stub" do
        snapshot = ClientJwks.resolver
        fake = Object.new
        fake.define_singleton_method(:getaddresses) { |_host| [ "10.0.0.5" ] }
        ClientJwks.resolver = fake
        assert_equal [ "10.0.0.5" ], ClientJwks.resolver.getaddresses("client.example.test")

        ClientJwks.resolver = snapshot
        assert_same snapshot, ClientJwks.resolver
      end

      private

      # How many times the JWKS is dialed for two fetches, `after` apart.
      def fetches_of_a_jwks_sent_with(cache_control, after: 0.seconds)
        stub_resolver("client.example.test" => [ "203.0.113.10" ])
        store = ActiveSupport::Cache::MemoryStore.new
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response["Cache-Control"] = cache_control if cache_control
        response.define_singleton_method(:body) { { keys: [ { kid: "one" } ] }.to_json }
        dials = 0
        pinned = ClientJwks.singleton_class
        original = pinned.instance_method(:pinned_get)
        pinned.define_method(:pinned_get) do |_uri, _address|
          dials += 1
          response
        end

        with_cache(store) do
          assert ClientJwks.fetch("https://client.example.test/jwks.json")
          travel(after) { assert ClientJwks.fetch("https://client.example.test/jwks.json") }
        end
        dials
      ensure
        pinned.define_method(:pinned_get, original)
        pinned.send(:private, :pinned_get)
      end

      def with_cache(store)
        previous = Rails.cache
        Rails.cache = store
        yield
      ensure
        Rails.cache = previous
      end

      def stub_resolver(mapping)
        fake = Object.new
        fake.define_singleton_method(:getaddresses) { |host| Array(mapping[host]) }
        ClientJwks.resolver = fake
      end

      def with_proxy_env
        saved = PROXY_KEYS.to_h { |key| [ key, ENV[key] ] }
        ENV["http_proxy"] = "http://127.0.0.1:9"
        ENV["https_proxy"] = "http://127.0.0.1:9"
        ENV["HTTP_PROXY"] = "http://127.0.0.1:9"
        ENV["HTTPS_PROXY"] = "http://127.0.0.1:9"
        ENV.delete("no_proxy")
        ENV.delete("NO_PROXY")
        yield
      ensure
        saved.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end

      # Minitest 6 has no Object#stub. Replace the singleton methods for the
      # duration of the fetch and put the originals back, including on error.
      def capture_dials
        dialed = []
        original_open = TCPSocket.method(:open)
        original_lookup = IPSocket.method(:getaddress)
        TCPSocket.define_singleton_method(:open) do |addr, port, *|
          dialed << [ addr, port ]
          raise Errno::ECONNREFUSED
        end
        IPSocket.define_singleton_method(:getaddress) { |_host| "203.0.113.10" }
        yield
        dialed
      ensure
        restore_singleton(TCPSocket, :open, original_open)
        restore_singleton(IPSocket, :getaddress, original_lookup)
      end

      def restore_singleton(klass, name, original)
        return unless original

        klass.define_singleton_method(name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      end
    end
  end
end
