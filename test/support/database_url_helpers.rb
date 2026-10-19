# frozen_string_literal: true

require "uri"

# URL helpers for integration tests that build scratch DATABASE_URLs and redact
# credentials in failure messages. Kept in test/support so they can be unit-tested
# without a database.
module DatabaseUrlHelpers
  module_function

  def redact_database_url(url)
    uri = URI.parse(url)
    query = redact_password_query_param(uri.query)
    URI::Generic.build(
      scheme: uri.scheme,
      userinfo: uri.userinfo ? "REDACTED" : nil,
      host: uri.host,
      port: uri.port,
      path: uri.path,
      query: query,
      fragment: uri.fragment
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

  def redact_password_query_param(query)
    return query if query.nil? || query.empty?

    query.split("&").map do |pair|
      key, = pair.split("=", 2)
      if key&.match?(/^password$/i)
        "#{key}=[REDACTED]"
      else
        pair
      end
    end.join("&")
  end
end
