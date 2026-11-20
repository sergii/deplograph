require "json"
require "net/http"
require "uri"

module Vulnerabilities
  class OsvClient
    class QueryError < StandardError; end

    API_URL = "https://api.osv.dev/v1/querybatch"
    MAX_PAGES = 20

    def initialize(endpoint: API_URL)
      @endpoint = URI(endpoint)
    end

    # Returns purl => vulnerability objects. All input PURLs must be versioned.
    def query_batch(purls)
      result = purls.uniq.to_h { |purl| [purl, []] }
      purls.uniq.each_slice(100) do |batch|
        pending = batch.map { |purl| { purl: purl, token: nil } }
        page = 0

        until pending.empty?
          page += 1
          raise QueryError, "OSV pagination limit exceeded" if page > MAX_PAGES

          queries = pending.map do |item|
            query = { package: { purl: item.fetch(:purl) } }
            query[:page_token] = item[:token] if item[:token]
            query
          end
          response = post(queries: queries)
          rows = response.fetch("results")
          raise QueryError, "OSV result count mismatch" unless rows.length == pending.length

          next_pending = []
          pending.zip(rows).each do |item, row|
            result.fetch(item[:purl]).concat(Array(row["vulns"]))
            if row["next_page_token"].present?
              next_pending << item.merge(token: row["next_page_token"])
            end
          end
          pending = next_pending
        end
      end
      result
    end

    private

    def post(payload)
      request = Net::HTTP::Post.new(@endpoint)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "Deplograph/0.1"
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(
        @endpoint.host, @endpoint.port,
        use_ssl: @endpoint.scheme == "https",
        open_timeout: 5, read_timeout: 20
      ) { |http| http.request(request) }

      raise QueryError, "OSV HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise QueryError, "Invalid OSV response: #{error.message}"
    end
  end
end
