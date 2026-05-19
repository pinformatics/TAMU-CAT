require "net/http"
require "uri"

# Lightweight endpoint to verify public accessibility of Google-hosted links (Drive, Docs, Sites, etc.).
# Performs a HEAD (with redirects) and falls back to a minimal GET when needed.
class EvidenceController < ApplicationController
  before_action :authenticate_user!

  # GET /evidence/check_access.json?url=...
  # Returns JSON: { ok: true/false, accessible: true/false, status: 200, reason: "ok|forbidden|..." }
  def check_access
    url = params[:url].to_s

    unless url =~ StudentQuestion::GOOGLE_URL_REGEX
      render json: { ok: false, accessible: false, status: nil, reason: "invalid_url" }
      return
    end

    begin
      response = fetch_with_redirects(url, limit: 3)
      code = response.code.to_i
      # Consider 200 as accessible. 302 handled by redirects.
      accessible = (code == 200)
      render json: { ok: true, accessible: accessible, status: code, reason: reason_from_code(code) }
    rescue => _e
      render json: { ok: false, accessible: false, status: nil, reason: "network_error" }
    end
  end

  private

  def fetch_with_redirects(url, limit: 3)
    raise "too_many_redirects" if limit <= 0

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5

    head = Net::HTTP::Head.new(uri.request_uri)
    head["User-Agent"] = "TamuCatLinkChecker/1.0"
    res = http.request(head)

    # Follow redirects
    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      return fetch_with_redirects(res["location"], limit: limit - 1)
    end

    # Some endpoints disallow HEAD; fall back to a minimal GET
    if res.code.to_i == 405 || res.is_a?(Net::HTTPMethodNotAllowed)
      get = Net::HTTP::Get.new(uri.request_uri)
      get["User-Agent"] = "TamuCatLinkChecker/1.0"
      get["Range"] = "bytes=0-0"
      res = http.request(get)
    end

    res
  end

  def reason_from_code(code)
    case code
    when 200 then "ok"
    when 401 then "unauthorized"
    when 403 then "forbidden"
    when 404 then "not_found"
    when 429 then "rate_limited"
    else "unavailable"
    end
  end
end
