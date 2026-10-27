# frozen_string_literal: true

require "uri"

# URL helpers for integration tests that build scratch DATABASE_URLs and redact
# credentials in failure messages. Kept in test/support so they can be unit-tested
# without a database.
module DatabaseUrlHelpers
  CONNECTION_URL_RESOLUTION_FAILURE = "could not resolve DATABASE_URL configuration"

  class ConnectionUrlResolutionError < StandardError; end

  module_function

  def redact_database_url(url)
    uri = URI.parse(url)
    query = redact_pass_like_query_params(uri.query)
    URI::Generic.build(
      scheme: uri.scheme,
      userinfo: uri.userinfo ? "REDACTED" : nil,
      host: uri.host,
      port: uri.port,
      path: uri.path,
      query: query
    ).to_s
  rescue URI::InvalidURIError, URI::InvalidComponentError
    "[invalid DATABASE_URL]"
  end

  def filter_database_dbname_query(query)
    return nil if query.nil? || query.empty?

    filtered = query.split("&").reject do |pair|
      key = pair.split("=", 2).first
      %w[database dbname].include?(key)
    end
    filtered.empty? ? nil : filtered.join("&")
  end

  def scratch_database_path_and_query(uri, scratch_db)
    uri = uri.dup
    uri.query = filter_database_dbname_query(uri.query) if uri.query.present?
    uri.path = "/#{scratch_db}"
    uri.to_s
  end

  def build_postgresql_url_from_config(hash, scratch_db)
    username = hash[:username] || hash[:user]
    password = hash[:password]
    host = hash[:host]
    port = hash[:port]

    if host.blank? || host.to_s.start_with?("/")
      query_parts = []
      query_parts << "host=#{URI.encode_uri_component(host)}" if host.present?
      query_parts << "port=#{URI.encode_uri_component(port.to_s)}" if port
      query_parts << "username=#{URI.encode_uri_component(username)}" if username.present?
      query_parts << "password=#{URI.encode_uri_component(password)}" if password

      base = "postgresql:///#{scratch_db}"
      return query_parts.empty? ? base : "#{base}?#{query_parts.join('&')}"
    end

    userinfo = encode_userinfo(username, password)
    auth = userinfo ? "#{userinfo}@" : ""
    port_fragment = port ? ":#{port}" : ""
    host_fragment = format_host_for_authority(host)
    "postgresql://#{auth}#{host_fragment}#{port_fragment}/#{scratch_db}"
  end

  def resolve_connection_url_hash(database_url)
    require "active_record/database_configurations"

    ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.new(database_url).to_hash
  rescue URI::InvalidURIError, ArgumentError
    raise ConnectionUrlResolutionError, CONNECTION_URL_RESOLUTION_FAILURE
  end

  def safe_resolved_database_from_url(database_url)
    resolve_connection_url_hash(database_url)[:database]
  rescue ConnectionUrlResolutionError
    nil
  end

  def encode_userinfo(username, password)
    return nil if username.blank?

    user = URI.encode_uri_component(username)
    return user unless password

    "#{user}:#{URI.encode_uri_component(password)}"
  end
  module_function :encode_userinfo

  def format_host_for_authority(host)
    host_string = host.to_s
    return host_string if host_string.start_with?("[") && host_string.end_with?("]")

    host_string.include?(":") ? "[#{host_string}]" : host_string
  end
  module_function :format_host_for_authority

  def redact_pass_like_query_params(query)
    return query if query.nil? || query.empty?

    query.split("&").map do |pair|
      key, = pair.split("=", 2)
      if key&.match?(/pass/i)
        "#{key}=[REDACTED]"
      else
        pair
      end
    end.join("&")
  end
  module_function :redact_pass_like_query_params
end
