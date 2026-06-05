# frozen_string_literal: true

require "net/http"
require "uri"

# Shared Google Sites evidence-link validation for real survey submit and
# admin preview submit. Returns [accessible_boolean, reason_symbol].
class EvidenceLinkChecker
  ACCESS_REQUIRED_PATTERN = /(you need access|request access|sign in to continue|don[’']t have access|do not have access)/i.freeze
  PUBLIC_MARKER_PATTERN = /(open with google docs|file|view only|anyone with the link)/i.freeze
  ALLOWLIST_HOSTS = %w[sites.google.com].freeze
  ALLOWLIST_SUFFIXES = %w[googleusercontent.com].freeze
  USER_AGENT = "TamuCatLinkChecker/1.0"

  def self.call(url)
    new(url).call
  end

  def initialize(url)
    @url = url.to_s
  end

  def call
    uri = parse_start_uri
    return [ false, :invalid ] unless uri

    redirects = 0
    current_uri = uri

    loop do
      response = head_response(current_uri)

      case response
      when Net::HTTPSuccess
        return sniff_access(current_uri)
      when Net::HTTPRedirection
        location = response["location"]
        return [ false, :error ] if location.blank?

        redirects += 1
        return [ false, :too_many_redirects ] if redirects > 3

        current_uri = URI.parse(location)
        return [ false, :forbidden ] unless allowlisted_host?(current_uri.host)
      when Net::HTTPForbidden
        return [ false, :forbidden ]
      when Net::HTTPNotFound
        return [ false, :not_found ]
      when Net::HTTPMethodNotAllowed
        return get_fallback_access(current_uri)
      else
        return [ false, :error ]
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      return [ false, :timeout ]
    rescue StandardError
      return [ false, :error ]
    end
  end

  private

  attr_reader :url

  def parse_start_uri
    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTPS)
    return unless allowlisted_host?(uri.host)

    uri
  rescue URI::InvalidURIError
    nil
  end

  def allowlisted_host?(host)
    candidate = host.to_s.downcase
    ALLOWLIST_HOSTS.include?(candidate) ||
      ALLOWLIST_SUFFIXES.any? { |suffix| candidate == suffix || candidate.end_with?(".#{suffix}") }
  end

  def http_for(uri)
    Net::HTTP.new(uri.host, uri.port).tap do |http|
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
    end
  end

  def head_response(uri)
    request = Net::HTTP::Head.new(uri.request_uri)
    request["User-Agent"] = USER_AGENT
    http_for(uri).request(request)
  end

  def get_response(uri, range:)
    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = USER_AGENT
    request["Range"] = range
    http_for(uri).request(request)
  end

  def sniff_access(uri)
    response = get_response(uri, range: "bytes=0-2047")
    if response.is_a?(Net::HTTPSuccess)
      body = response.body.to_s
      return [ false, :forbidden ] if body.match?(ACCESS_REQUIRED_PATTERN)
      return [ true, :ok ] if body.match?(PUBLIC_MARKER_PATTERN)
    end

    [ true, :ok ]
  rescue Net::OpenTimeout, Net::ReadTimeout
    [ false, :timeout ]
  rescue StandardError
    [ true, :ok ]
  end

  def get_fallback_access(uri)
    response = get_response(uri, range: "bytes=0-0")
    return [ false, :error ] unless response.is_a?(Net::HTTPSuccess)

    sniff_access(uri)
  end
end
