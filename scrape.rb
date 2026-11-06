#!/usr/bin/env ruby
# frozen_string_literal: true
#
# at-list-scraper: reads Bluesky list URLs from lists.md and appends every
# member not already present to accounts.csv. Ruby standard library only.
#
#   ruby scrape.rb          run it
#   ruby scrape.rb --help   usage, file format, exit codes

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.6')
  abort "at-list-scraper needs Ruby 2.6 or newer (this is Ruby #{RUBY_VERSION})."
end

require 'io/console'
require 'json'
require 'net/http'
require 'openssl'
require 'set'
require 'uri'
require 'zlib'

begin
  require 'csv'
rescue LoadError
  abort "Ruby's csv library is missing. Install it with:  gem install csv"
end

module AtListScraper
  ROOT         = __dir__
  LISTS_PATH   = File.join(ROOT, 'lists.md')
  HOSTS_PATH   = File.join(ROOT, 'hosts.txt')
  CSV_PATH     = File.join(ROOT, 'accounts.csv')
  APPVIEW      = ENV.fetch('BSKY_APPVIEW', 'https://public.api.bsky.app')
  PROFILE_BASE = 'https://mu.social/profile/'
  COLUMNS      = %w[did alias handle displayName description verified verifiedBy customDomain profileUrl].freeze
  PAGE_SIZE    = 100
  MAX_ATTEMPTS = 4
  USER_AGENT   = 'at-list-scraper/1.0 (+https://github.com/renderghost/at-list-scraper)'

  USAGE = <<~TEXT
    Usage: ruby scrape.rb

    Reads Bluesky list URLs from lists.md and appends every member whose DID is
    not already in accounts.csv. Both files live next to this script.

    lists.md: one list per line. Any Bluesky-compatible client URL works.
      https://mu.social/profile/aendra.com/lists/3kmsxmhakdw27
      - https://bsky.app/profile/did:plc:kkf4naxqmweop7dv4l2iqqf5/lists/3kmsxmhakdw27
      at://aendra.com/app.bsky.graph.list/3kmsxmhakdw27
    A leading Markdown bullet, `backticks`, <angle brackets> or [text](url) are
    accepted. Blank lines and lines starting with # are ignored. Anything else is
    reported as an error, with its line number.

    hosts.txt: domains that hand out handles to anyone (bsky.social, brid.gy, ...),
    one per line. Accounts with a handle under one of them get customDomain FALSE.

    accounts.csv columns: #{COLUMNS.join(', ')}
      verified      TRUE if the account currently has a valid Bluesky verification
      verifiedBy    who verified it (e.g. bsky.app), several joined with " | "
      customDomain  TRUE if the handle is not under a domain listed in hosts.txt

    Exit codes:
      0    every list scraped
      1    finished, but some lines or lists failed (see the summary)
      2    stopped early (missing lists.md, unreadable accounts.csv, network down, ...)
      130  interrupted with Ctrl-C (finished lists are already saved)

    Environment:
      BSKY_APPVIEW  API host to query (default https://public.api.bsky.app)
      NO_COLOR      set to disable coloured output
  TEXT

  # Stops the whole run.
  class FatalError < StandardError; end

  # Fails one list; the run carries on with the next.
  class ListError < StandardError; end

  # A deliberate error response from the API (4xx). Retrying will not help.
  class XrpcError < StandardError
    attr_reader :status, :code

    def initialize(status, code, message)
      @status = status
      @code = code
      super(message)
    end

    def detail
      code ? "HTTP #{status} #{code}" : "HTTP #{status}"
    end
  end

  # A response worth retrying: rate limiting or a server-side failure.
  class RetryableError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: nil, rate_limited: false)
      @retry_after = retry_after
      @rate_limited = rate_limited
      super(message)
    end

    def rate_limited?
      @rate_limited
    end
  end

  NETWORK_ERRORS = [
    Timeout::Error, SocketError, EOFError, IOError, OpenSSL::SSL::SSLError,
    Net::HTTPBadResponse, Zlib::Error,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ENETDOWN, Errno::ETIMEDOUT
  ].freeze

  # ---------------------------------------------------------------------------
  # Terminal output
  # ---------------------------------------------------------------------------
  class UI
    def initialize(out = $stdout, err = $stderr)
      @out = out
      @err = err
      @tty = out.tty?
      @color = @tty && ENV['NO_COLOR'].to_s.empty? && ENV['TERM'] != 'dumb'
      @live = false
    end

    # A transient line that the next output overwrites (terminals only).
    def status(text)
      return unless @tty

      @out.print "\r\e[2K#{fit(text)}"
      @out.flush
      @live = true
    end

    # Like status, but kept as a permanent line when output is not a terminal,
    # so logs still show retries.
    def note(text)
      @tty ? status(text) : say(text)
    end

    def say(text = '')
      clear
      @out.puts text
    end

    def error(text)
      clear
      @err.puts text
    end

    def clear
      return unless @live

      @out.print "\r\e[2K"
      @out.flush
      @live = false
    end

    { green: 32, red: 31, yellow: 33, bold: 1, dim: 2 }.each do |name, code|
      define_method(name) { |text| paint(text, code) }
    end

    private

    def paint(text, code)
      @color ? "\e[#{code}m#{text}\e[0m" : text
    end

    def fit(text)
      width = begin
        @out.winsize[1]
      rescue StandardError
        80
      end
      width = 80 if width.nil? || width < 20
      text.length < width ? text : "#{text[0, width - 2]}…"
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP client for the AppView's XRPC endpoints
  # ---------------------------------------------------------------------------
  class Client
    def initialize(base_url)
      @base = URI(base_url)
      unless @base.is_a?(URI::HTTP) && @base.host
        raise FatalError, "BSKY_APPVIEW must be an http(s) URL (got #{base_url.inspect})"
      end

      @proxy = @base.find_proxy
      @http = nil
    rescue URI::InvalidURIError
      raise FatalError, "BSKY_APPVIEW is not a valid URL (got #{base_url.inspect})"
    end

    def host
      @base.host
    end

    # Calls an XRPC query and returns the parsed JSON object. Network errors,
    # 429s and 5xx responses are retried with backoff; before each retry the
    # block (if given) receives (next_attempt, delay_seconds, reason).
    def get(nsid, params)
      path = "#{@base.path.chomp('/')}/xrpc/#{nsid}?#{URI.encode_www_form(params)}"
      attempt = 0
      begin
        attempt += 1
        parse(connection.request(build_request(path)))
      rescue RetryableError, *NETWORK_ERRORS => e
        network = !e.is_a?(RetryableError)
        if network
          disconnect
          check_tls!(e)
        end
        reason = network ? describe_network_error(e) : e.message
        raise give_up(e, reason, attempt) if attempt >= MAX_ATTEMPTS

        delay = e.is_a?(RetryableError) && e.retry_after ? e.retry_after : backoff(attempt)
        yield(attempt + 1, delay, reason) if block_given?
        sleep delay
        retry
      end
    end

    def close
      disconnect
    end

    private

    def connection
      return @http if @http&.started?

      http = if @proxy
               Net::HTTP.new(@base.host, @base.port, @proxy.host, @proxy.port, @proxy.user, @proxy.password)
             else
               Net::HTTP.new(@base.host, @base.port, nil)
             end
      http.use_ssl = @base.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30
      http.write_timeout = 10 if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30
      http.start
      @http = http
    end

    def disconnect
      @http.finish if @http&.started?
    rescue StandardError
      nil
    ensure
      @http = nil
    end

    def build_request(path)
      request = Net::HTTP::Get.new(path)
      request['User-Agent'] = USER_AGENT
      request['Accept'] = 'application/json'
      request
    end

    def parse(response)
      status = response.code.to_i
      body = response.body.to_s
      case status
      when 200
        data = json(body)
        return data if data.is_a?(Hash)

        raise RetryableError, "HTTP 200 but the response wasn't a JSON object (starts: #{snippet(body)})"
      when 429
        raise RetryableError.new('rate-limited (HTTP 429)', retry_after: retry_after(response), rate_limited: true)
      when 500..599
        raise RetryableError, "#{xrpc_message(body) || response.message} (HTTP #{status})"
      else
        data = json(body)
        if data.is_a?(Hash) && data['message']
          raise XrpcError.new(status, data['error'], data['message'])
        end

        raise XrpcError.new(status, nil, "unexpected response #{status} #{response.message} (starts: #{snippet(body)})")
      end
    end

    def json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def xrpc_message(body)
      data = json(body)
      return nil unless data.is_a?(Hash)

      [data['error'], data['message']].compact.join(': ').then { |m| m.empty? ? nil : m }
    end

    def snippet(body)
      text = body.to_s.gsub(/\s+/, ' ').strip
      text.empty? ? '(empty)' : text[0, 80].inspect
    end

    # Honours Retry-After (seconds) or RateLimit-Reset (epoch seconds), capped.
    def retry_after(response)
      if (value = response['retry-after']) && value =~ /\A\d+\z/
        return value.to_i.clamp(1, 60)
      end
      if (reset = response['ratelimit-reset']) && reset =~ /\A\d+\z/
        return (reset.to_i - Time.now.to_i).clamp(1, 60)
      end

      nil
    end

    def backoff(attempt)
      (2**(attempt - 1)) + rand * 0.3
    end

    def check_tls!(error)
      return unless error.is_a?(OpenSSL::SSL::SSLError) && error.message.include?('certificate verify failed')

      raise FatalError, "TLS certificate verification failed for #{host} (#{error.message}). " \
                        'If you are behind a corporate proxy, point SSL_CERT_FILE at its CA bundle.'
    end

    def describe_network_error(error)
      case error
      when Timeout::Error then 'request timed out'
      when SocketError then "DNS lookup for #{host} failed (offline?)"
      when Errno::ECONNREFUSED then 'connection refused'
      when Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE, EOFError then 'connection dropped'
      when Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ENETDOWN then 'network unreachable (offline?)'
      else "#{error.class.name.split('::').last}: #{error.message}"
      end
    end

    def give_up(error, reason, attempts)
      tries = "gave up after #{attempts} attempts"
      resume = 'Re-run when it clears; accounts already saved are skipped.'
      if error.is_a?(RetryableError) && error.rate_limited?
        FatalError.new("the Bluesky API is rate-limiting this machine (#{tries}). Wait a few minutes. #{resume}")
      elsif error.is_a?(RetryableError)
        ListError.new("the API kept failing: #{reason} (#{tries})")
      else
        FatalError.new("can't reach #{host}: #{reason} (#{tries}). Check your connection. #{resume}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # lists.md parsing (strict: one list per line)
  # ---------------------------------------------------------------------------
  ListEntry = Struct.new(:line, :text, :owner, :rkey) do
    def label
      "#{owner}/#{rkey}"
    end
  end

  Problem = Struct.new(:line, :text, :reason)

  module ListsFile
    URL_FORM  = %r{\Ahttps?://[^/\s]+/profile/([^/\s?#]+)/lists/([^/\s?#]+)/?(?:[?#]\S*)?\z}i.freeze
    AT_FORM   = %r{\Aat://([^/\s]+)/app\.bsky\.graph\.list/([^/\s?#]+)\z}.freeze
    HANDLE    = /\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/i.freeze
    DID       = /\Adid:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]\z/.freeze
    RKEY      = /\A[A-Za-z0-9._:~-]{1,512}\z/.freeze
    EXPECTED  = 'expected https://<client>/profile/<owner>/lists/<list-id>'

    module_function

    # Returns [entries, problems, duplicates]; duplicates are [line, first_line].
    def parse(path)
      text = read(path)
      entries = []
      problems = []
      duplicates = []
      first_seen = {}

      text.each_line.with_index(1) do |raw, number|
        line = raw.strip
        next if line.empty? || line.start_with?('#')

        result = parse_line(line)
        if result.is_a?(String)
          problems << Problem.new(number, line, result)
          next
        end

        owner, rkey = result
        key = "#{owner}/#{rkey}"
        if first_seen[key]
          duplicates << [number, first_seen[key]]
        else
          first_seen[key] = number
          entries << ListEntry.new(number, line, owner, rkey)
        end
      end

      if entries.empty? && problems.empty?
        raise FatalError, "#{File.basename(path)} has no list URLs. Add one per line, e.g.\n  " \
                          'https://mu.social/profile/aendra.com/lists/3kmsxmhakdw27'
      end

      [entries, problems, duplicates]
    end

    def read(path, missing: nil)
      raw = File.binread(path)
      text = raw.force_encoding(Encoding::UTF_8).delete_prefix("﻿")
      raise FatalError, "#{File.basename(path)} isn't valid UTF-8 text." unless text.valid_encoding?

      text
    rescue Errno::ENOENT
      raise FatalError, "#{File.basename(path)} not found. #{missing || "Create #{path} with one list URL per line."}"
    rescue Errno::EISDIR
      raise FatalError, "#{path} is a directory, not a file."
    rescue SystemCallError => e
      raise FatalError, "can't read #{File.basename(path)}: #{e.message}"
    end

    # Returns [owner, rkey] or a String explaining why the line was rejected.
    def parse_line(line)
      item = line.sub(/\A(?:[-*+]|\d+[.)])\s+/, '')                 # Markdown bullet
      item = item[1..-2].strip if item =~ /\A`.+`\z/ || item =~ /\A<.+>\z/
      item = Regexp.last_match(1) if item =~ /\A\[[^\]]*\]\((\S+)\)\z/ # [text](url)
      return 'more than one item on this line; put one list URL per line' if item =~ /\s/

      match = URL_FORM.match(item) || AT_FORM.match(item)
      return not_a_list(item) unless match

      owner = match[1].gsub(/%([0-9a-f]{2})/i) { Regexp.last_match(1).hex.chr }
      owner = owner.downcase unless owner.start_with?('did:')
      rkey = match[2]
      return "#{owner.inspect} isn't a valid handle or DID" unless owner =~ HANDLE || owner =~ DID
      return "#{rkey.inspect} isn't a valid list ID" unless rkey =~ RKEY && !%w[. ..].include?(rkey)

      [owner, rkey]
    end

    def not_a_list(item)
      return "not a URL; #{EXPECTED}" unless item =~ %r{\A(?:https?|at)://}i

      case item
      when %r{/profile/[^/]+/feed/}i then 'this is a feed URL, not a list'
      when %r{/profile/[^/]+/post/}i then 'this is a post URL, not a list'
      when %r{/(?:starter-pack|start)/}i then 'this is a starter pack URL, not a list'
      when %r{/profile/[^/]+/lists/?\z}i then 'the list ID after /lists/ is missing'
      when %r{/profile/[^/]+/?\z}i then 'this is a profile URL, not a list'
      else "not a list URL; #{EXPECTED}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # hosts.txt: domains whose subdomain handles are not custom domains
  # ---------------------------------------------------------------------------
  class Hosts
    attr_reader :size

    # Strict: any bad line stops the run, because a typo here would silently
    # write wrong customDomain values into an append-only file.
    def self.load(path)
      text = ListsFile.read(path, missing: 'It lists the handle hosts (bsky.social, brid.gy, ...) used to decide ' \
                                           "customDomain. Restore it from the repository, or create #{path}.")
      domains = Set.new
      problems = []
      text.each_line.with_index(1) do |raw, number|
        line = raw.sub(/#.*/, '').strip
        next if line.empty?

        domain = line.downcase.sub(/\A\*?\./, '')
        if domain =~ /\s/
          problems << "  line #{number}: one domain per line (got #{line.inspect})"
        elsif domain !~ ListsFile::HANDLE
          problems << "  line #{number}: #{line.inspect} isn't a domain name"
        else
          domains << domain
        end
      end

      unless problems.empty?
        raise FatalError, "#{File.basename(path)} has #{problems.size == 1 ? 'a line' : 'lines'} " \
                          "that aren't domains:\n#{problems.join("\n")}"
      end
      if domains.empty?
        raise FatalError, "#{File.basename(path)} lists no domains. Add at least bsky.social, one per line."
      end

      new(domains)
    end

    def initialize(domains)
      @domains = domains
      @size = domains.size
    end

    # True when the handle is a listed domain or any subdomain of one.
    def hosted?(handle)
      labels = handle.downcase.split('.')
      (0...labels.size).any? { |i| @domains.include?(labels[i..-1].join('.')) }
    end
  end

  # ---------------------------------------------------------------------------
  # accounts.csv: append-only, deduplicated by DID
  # ---------------------------------------------------------------------------
  class AccountStore
    attr_reader :size, :preexisting_count

    def initialize(path)
      @path = path
      @name = File.basename(path)
      @preexisting = Set.new
      @dids = Set.new
      @row_sep = "\n"
      @ends_with_newline = true
      @size = 0
      @preexisting_count = 0
    end

    def open!
      existing = File.file?(@path) && !File.zero?(@path)
      raise FatalError, "#{@path} is a directory, not a file." if File.directory?(@path)

      load! if existing
      @io = File.open(@path, 'a:utf-8')
      unless @io.flock(File::LOCK_EX | File::LOCK_NB)
        raise FatalError, "#{@name} is locked by another run of this script. Wait for it to finish."
      end

      if existing
        @io.write(@row_sep) unless @ends_with_newline
      else
        @io.write(CSV.generate_line(COLUMNS, row_sep: @row_sep))
      end
      @io.flush
      self
    rescue SystemCallError, IOError => e
      raise FatalError, "can't open #{@name} for writing: #{e.message}"
    end

    def preexisting?(did)
      @preexisting.include?(did)
    end

    def known?(did)
      @dids.include?(did)
    end

    def append(rows)
      return if rows.empty?

      @io.write(rows.map { |row| CSV.generate_line(row, row_sep: @row_sep) }.join)
      @io.flush
      rows.each { |row| @dids << row.first }
      @size += rows.size
    rescue SystemCallError, IOError => e
      raise FatalError, "couldn't write to #{@name}: #{e.message}"
    end

    def close
      @io&.close
    rescue IOError
      nil
    end

    private

    def load!
      raw = File.binread(@path)
      first_line = raw[/\A[^\n]*\n?/]
      @row_sep = "\r\n" if first_line.end_with?("\r\n")
      @ends_with_newline = raw.end_with?("\n")

      text = raw.force_encoding(Encoding::UTF_8).delete_prefix("﻿")
      raise FatalError, "#{@name} isn't valid UTF-8. Fix it, or move it aside to start a new file." unless text.valid_encoding?

      rows = parse_csv(text)
      check_header!(rows.shift)
      rows.each do |row|
        did = row.first.to_s.strip
        @preexisting << did unless did.empty?
      end
      @dids.merge(@preexisting)
      @size = @preexisting_count = @preexisting.size
    rescue SystemCallError => e
      raise FatalError, "can't read #{@name}: #{e.message}"
    end

    def parse_csv(text)
      CSV.parse(text)
    rescue CSV::MalformedCSVError => e
      raise FatalError, "#{@name} isn't valid CSV (#{e.message}). Fix it, or move it aside to start a new file."
    end

    def check_header!(header)
      found = Array(header).map { |cell| cell.to_s.strip }
      return if found == COLUMNS

      older = !found.empty? && (found - COLUMNS).empty?
      raise FatalError, "#{@name} has different columns from the ones this script writes" \
                        "#{older ? ' (it was made by an older version)' : ''}.\n" \
                        "  found:    #{found.join(',')}\n" \
                        "  expected: #{COLUMNS.join(',')}\n" \
                        'Move the file aside (e.g. rename it to accounts-old.csv) and re-run to start a fresh one.'
    end
  end

  # ---------------------------------------------------------------------------
  # The scrape itself
  # ---------------------------------------------------------------------------
  class Scraper
    def initialize(ui:, client:, store:, hosts:)
      @ui = ui
      @client = client
      @store = store
      @hosts = hosts
      @owners = {}   # handle => DID, or the ListError it raised
      @done = {}     # list AT-URI => lines.md line number
      @stats = Hash.new(0)
    end

    attr_reader :stats

    # Scrapes one list. Raises ListError (skip this list) or FatalError (stop).
    def scrape(entry, tag)
      started = clock
      did = resolve_owner(entry.owner, tag)
      uri = "at://#{did}/app.bsky.graph.list/#{entry.rkey}"

      if (first = @done[uri])
        @stats[:duplicate_lists] += 1
        @ui.say @ui.yellow("! #{tag} line #{entry.line}: same list as line #{first}; skipped")
        return
      end
      @done[uri] = entry.line

      info, members = fetch_list(uri, entry, tag)
      title = list_title(info)
      rows, already, repeated = save(members)
      added = rows.size
      verified = rows.count { |row| row[COLUMNS.index('verified')] == 'TRUE' }
      custom = rows.count { |row| row[COLUMNS.index('customDomain')] == 'TRUE' }

      @stats[:lists_ok] += 1
      @stats[:fetched] += members.size
      @stats[:added] += added
      @stats[:already] += already
      @stats[:repeated] += repeated
      @stats[:verified] += verified
      @stats[:custom_domain] += custom

      parts = ["#{added} new"]
      parts << "#{verified} verified, #{custom} custom domain" if added.positive?
      parts << "#{already} already saved" if already.positive?
      parts << "#{repeated} on an earlier list" if repeated.positive?
      @ui.say "#{@ui.green('✓')} #{tag} #{title}: #{plural(members.size, 'member')} " \
              "(#{parts.join(', ')}) #{@ui.dim(format('%.1fs', clock - started))}"
    end

    private

    def resolve_owner(owner, tag)
      return owner if owner.start_with?('did:')

      cached = @owners[owner]
      raise cached if cached.is_a?(ListError)
      return cached if cached

      @ui.status "#{tag} @#{owner}: resolving owner…"
      data = @client.get('com.atproto.identity.resolveHandle', handle: owner) do |attempt, delay, reason|
        @ui.note "#{tag} @#{owner}: #{reason}; retrying in #{format('%.0f', delay)}s (attempt #{attempt}/#{MAX_ATTEMPTS})"
      end
      did = data['did']
      raise ListError, "the API resolved @#{owner} but returned no DID" unless did.is_a?(String) && did.start_with?('did:')

      @owners[owner] = did
    rescue XrpcError => e
      error = if e.status == 400
                ListError.new("couldn't resolve owner @#{owner}: account deleted or renamed, " \
                              "or a typo in the handle (#{e.message}; #{e.detail})")
              else
                ListError.new("couldn't resolve owner @#{owner}: #{e.message} (#{e.detail})")
              end
      @owners[owner] = error
      raise error
    end

    def fetch_list(uri, entry, tag)
      members = []
      cursors = Set.new
      cursor = nil
      info = nil
      title = entry.label

      loop do
        params = { list: uri, limit: PAGE_SIZE }
        params[:cursor] = cursor if cursor
        data = @client.get('app.bsky.graph.getList', params) do |attempt, delay, reason|
          @ui.note "#{tag} #{title}: #{reason}; retrying in #{format('%.0f', delay)}s (attempt #{attempt}/#{MAX_ATTEMPTS})"
        end

        info ||= data['list']
        items = data['items']
        unless info.is_a?(Hash) && items.is_a?(Array)
          raise ListError, 'unexpected response from the API (no list or items in it)'
        end

        title = list_title(info)
        items.each do |item|
          subject = item.is_a?(Hash) ? item['subject'] : nil
          if subject.is_a?(Hash) && subject['did'].is_a?(String)
            members << subject
          else
            @stats[:malformed] += 1
          end
        end

        total = info['listItemCount']
        @ui.status "#{tag} #{title}: fetched #{members.size}#{total ? " of #{total}" : ''}…"

        cursor = data['cursor']
        break if cursor.nil? || cursor.to_s.empty? || items.empty?
        raise ListError, 'the API repeated a page cursor; stopped to avoid looping forever' unless cursors.add?(cursor)
      end

      [info, members]
    rescue XrpcError => e
      if e.status == 400 && e.message =~ /not found/i
        raise ListError, "list not found: deleted, or the list ID is wrong (#{e.detail})"
      end

      raise ListError, "the API rejected the request: #{e.message} (#{e.detail})"
    end

    # Appends members not seen before. Returns [rows_added, already_saved, repeated].
    def save(members)
      rows = []
      batch = Set.new
      already = 0
      repeated = 0

      members.each do |subject|
        did = subject['did']
        if @store.preexisting?(did)
          already += 1
        elsif @store.known?(did) || !batch.add?(did)
          repeated += 1
        else
          rows << row_for(subject)
        end
      end

      @store.append(rows)
      [rows, already, repeated]
    end

    # Must stay in the same order as COLUMNS.
    def row_for(subject)
      did = subject['did']
      handle = subject['handle'].to_s.downcase
      valid = !handle.empty? && handle != 'handle.invalid'
      @stats[:invalid_handles] += 1 unless valid
      handle = 'handle.invalid' if handle.empty?
      verified, verified_by = verification(subject['verification'])

      [
        did,
        valid ? "at://#{handle}" : "at://#{did}",
        "@#{handle}",
        flatten(subject['displayName']),
        flatten(subject['description']),
        boolean(verified),
        verified_by,
        boolean(valid && !@hosts.hosted?(handle)),
        "#{PROFILE_BASE}#{did}"
      ]
    end

    # Verified only while Bluesky rates it valid now. A verification lapses if
    # the account changes its handle or display name. Returns [bool, issuers].
    def verification(data)
      return [false, ''] unless data.is_a?(Hash) && data['verifiedStatus'] == 'valid'

      issuers = Array(data['verifications']).select { |v| v.is_a?(Hash) && v['isValid'] }
                                            .map { |v| flatten(v['issuerHandle'] || v['issuer']) }
                                            .reject(&:empty?).uniq
      [true, issuers.join(' | ')]
    end

    def boolean(value)
      value ? 'TRUE' : 'FALSE'
    end

    def list_title(info)
      name = flatten(info['name'])
      name = 'Untitled list' if name.empty?
      creator = info.dig('creator', 'handle')
      creator ? "#{name} (@#{creator})" : name
    end

    # One line per account: line breaks and control characters become a space.
    def flatten(value)
      value.to_s.scrub('')
           .gsub(/[ \t]*[\r\n\u0085  ]+[ \t]*/, ' ')
           .gsub(/[[:cntrl:]]/, ' ')
           .strip
    end

    def plural(count, word)
      "#{AtListScraper.number(count)} #{word}#{count == 1 ? '' : 's'}"
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------
  module_function

  def number(value)
    value.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
  end

  def run(argv)
    if argv.include?('-h') || argv.include?('--help')
      puts USAGE
      return 0
    end
    unless argv.empty?
      warn "Unknown argument(s): #{argv.join(' ')}\n\n#{USAGE}"
      return 2
    end

    $stdout.sync = true # keep stdout and stderr in order when piped
    ui = UI.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    problems = []
    store = nil
    client = nil
    scraper = nil
    entries = []
    duplicates = []
    stopped = nil
    interrupted = false

    begin
      client = Client.new(APPVIEW)
      hosts = Hosts.load(HOSTS_PATH)
      entries, line_problems, duplicates = ListsFile.parse(LISTS_PATH)
      ui.say ui.bold("lists.md: #{number(entries.size)} list#{entries.size == 1 ? '' : 's'} to scrape")
      line_problems.each do |problem|
        problems << problem
        ui.say "#{ui.red('✗')} line #{problem.line}: #{problem.reason}\n    #{ui.dim(problem.text)}"
      end
      duplicates.each do |line, first|
        ui.say ui.yellow("! line #{line}: same list as line #{first}; skipped")
      end
      raise FatalError, 'lists.md has no valid list URLs; nothing to scrape.' if entries.empty?

      store = AccountStore.new(CSV_PATH).open!
      ui.say(if store.preexisting_count.positive?
               "accounts.csv: #{number(store.preexisting_count)} accounts already saved; their DIDs will be skipped"
             else
               'accounts.csv: starting a new file'
             end)
      ui.say "hosts.txt: #{number(hosts.size)} handle hosts (handles under these are not custom domains)"
      ui.say

      scraper = Scraper.new(ui: ui, client: client, store: store, hosts: hosts)
      width = entries.size.to_s.length
      entries.each_with_index do |entry, index|
        tag = "[#{(index + 1).to_s.rjust(width)}/#{entries.size}]"
        begin
          scraper.scrape(entry, tag)
        rescue ListError => e
          problems << Problem.new(entry.line, entry.text, e.message)
          ui.say "#{ui.red('✗')} #{tag} line #{entry.line} #{entry.label}: #{e.message}"
        end
      end
    rescue FatalError => e
      stopped = e.message
    rescue Interrupt
      interrupted = true
    ensure
      client&.close
      store&.close
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    if store.nil?
      ui.error "#{ui.red('Error:')} #{stopped}" if stopped
      ui.error 'Interrupted.' if interrupted
      return interrupted ? 130 : 2
    end

    stats = scraper ? scraper.stats : Hash.new(0)
    stats[:duplicate_lists] += duplicates.size
    summarise(ui, stats, store, entries, problems, elapsed, stopped, interrupted)
    return 130 if interrupted
    return 2 if stopped

    problems.empty? ? 0 : 1
  end

  def plural(count, word)
    "#{number(count)} #{word}#{count == 1 ? '' : 's'}"
  end

  def summarise(ui, stats, store, entries, problems, elapsed, stopped, interrupted)
    ui.say
    list_lines = entries.map(&:line)
    failed_lists = problems.count { |p| list_lines.include?(p.line) }
    bad_lines = problems.size - failed_lists
    headline = "#{stats[:lists_ok]} of #{plural(entries.size, 'list')} scraped in #{format('%.1f', elapsed)}s"
    extras = []
    extras << "#{failed_lists} failed" if failed_lists.positive?
    extras << "#{plural(bad_lines, 'line')} in lists.md not understood" if bad_lines.positive?
    headline += " (#{extras.join(', ')})" unless extras.empty?

    if interrupted
      ui.say ui.yellow("Interrupted. #{headline}.")
      ui.say ui.yellow('The list in progress was discarded. Re-run to continue; saved DIDs are skipped.')
    elsif stopped
      ui.say "#{ui.red('Stopped:')} #{stopped}"
      ui.say "#{headline} before stopping."
    else
      ui.say ui.bold(problems.empty? ? ui.green("Done. #{headline}.") : "Done with problems. #{headline}.")
    end

    ui.say "  #{number(stats[:fetched]).rjust(7)} members fetched"
    ui.say "  #{number(stats[:added]).rjust(7)} new accounts added to accounts.csv (now #{number(store.size)})"
    if stats[:added].positive?
      ui.say "  #{number(stats[:verified]).rjust(7)} of them verified, " \
             "#{number(stats[:custom_domain])} with a custom domain"
    end
    ui.say "  #{number(stats[:already]).rjust(7)} already in accounts.csv, skipped" if stats[:already].positive?
    ui.say "  #{number(stats[:repeated]).rjust(7)} on more than one list, saved once" if stats[:repeated].positive?
    if stats[:duplicate_lists].positive?
      ui.say "  #{number(stats[:duplicate_lists]).rjust(7)} duplicate list #{stats[:duplicate_lists] == 1 ? 'URL' : 'URLs'} skipped"
    end
    if (count = stats[:invalid_handles]).positive?
      ui.say ui.yellow("  #{number(count).rjust(7)} #{count == 1 ? 'account has' : 'accounts have'} no valid handle " \
                       '(alias uses at://<did>, handle is @handle.invalid)')
    end
    if (count = stats[:malformed]).positive?
      ui.say ui.yellow("  #{number(count).rjust(7)} list #{count == 1 ? 'entry' : 'entries'} had no account data, skipped")
    end

    return if problems.empty?

    ui.say
    ui.say ui.red(ui.bold("#{plural(problems.size, 'problem')}, by lists.md line:"))
    problems.sort_by(&:line).each do |problem|
      ui.say "  line #{problem.line}: #{problem.reason}"
      ui.say "    #{ui.dim(problem.text)}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit AtListScraper.run(ARGV)
  rescue Errno::EPIPE
    exit 0
  rescue Interrupt
    warn "\nInterrupted."
    exit 130
  rescue StandardError => e
    warn "Unexpected error (a bug in scrape.rb; please report it): #{e.class}: #{e.message}"
    e.backtrace.first(5).each { |frame| warn "  #{frame}" }
    exit 2
  end
end
