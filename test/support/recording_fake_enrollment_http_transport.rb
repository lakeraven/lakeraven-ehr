# frozen_string_literal: true

# Scripted HTTP transport for EnrollmentFHIRClient specs. Records every
# #post(url, body:, headers:) and #get(url, headers:) call; each returns an
# object with #code and #body. Queue responses with #queue_post / #queue_get,
# or #raise_on_every_post / #raise_on_every_get for errors on every attempt
# once the queue is exhausted.
class RecordingFakeEnrollmentHttpTransport
  Response = Struct.new(:code, :body, keyword_init: true)

  attr_reader :calls

  def initialize
    @calls = []
    @post_queue = []
    @get_queue = []
    @post_raise = nil
    @get_raise = nil
    @default_post = Response.new(code: 200, body: "")
    @default_get = Response.new(code: 200, body: "{}")
  end

  def queue_post(*entries)
    @post_queue.concat(entries.map { |entry| normalize_entry(entry) })
    self
  end

  def queue_get(*entries)
    @get_queue.concat(entries.map { |entry| normalize_entry(entry) })
    self
  end

  def raise_on_every_post(exception)
    @post_raise = exception
    self
  end

  def raise_on_every_get(exception)
    @get_raise = exception
    self
  end

  def reset!
    @calls.clear
    @post_queue.clear
    @get_queue.clear
    @post_raise = nil
    @get_raise = nil
    self
  end

  def post(url, body:, headers:)
    @calls << { method: :post, url: url, headers: headers, body: body }
    dispatch(@post_queue, @default_post, @post_raise)
  end

  def get(url, headers:)
    @calls << { method: :get, url: url, headers: headers, body: nil }
    dispatch(@get_queue, @default_get, @get_raise)
  end

  def posts_to(url)
    @calls.select { |call| call[:method] == :post && call[:url] == url }
  end

  def gets_starting_with(url_prefix)
    @calls.select { |call| call[:method] == :get && call[:url].start_with?(url_prefix) }
  end

  private

  def dispatch(queue, default, repeat_raise)
    if queue.empty?
      raise repeat_raise if repeat_raise

      return default
    end

    entry = queue.shift
    raise entry if entry.is_a?(Exception)

    entry.is_a?(Response) ? entry : Response.new(code: entry[:code], body: serialize_body(entry[:body]))
  end

  def normalize_entry(entry)
    case entry
    when Response then entry
    when Hash
      Response.new(code: entry[:status] || entry[:code] || 200, body: serialize_body(entry[:body]))
    when Exception then entry
    else
      entry
    end
  end

  def serialize_body(body)
    body.is_a?(String) ? body : body.to_json
  end
end
