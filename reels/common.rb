# Shared helpers: config, GitHub API, captions. Used by production (reelmaker.rb) and publishing (publish.rb), in the cloud or locally.
Encoding.default_external = 'UTF-8'
require 'net/http'
require 'json'
require 'base64'
require 'uri'

module Common
  ROOT   = File.expand_path('..', __dir__)
  CONFIG = File.join(ROOT, 'config.env')
  RELEASE_TAG = 'reels-bank'
  SOURCES_TAG = 'reels-sources'   # original videos + transcripts, so the cloud never has to re-download or re-transcribe
  BACKUP_TAG  = 'backups'
  CLOUD = !ENV['GITHUB_ACTIONS'].to_s.empty? || !ENV['NABD_CLOUD'].to_s.empty?

  # Find a program: env override (e.g. FFMPEG=/path), then the project's own copy (Mac), then PATH (Linux/cloud).
  def self.tool(name, env, *local)
    return ENV[env] if ENV[env] && !ENV[env].empty?
    local.map { |p| File.join(ROOT, p) }.find { |p| File.executable?(p) } ||
      ENV['PATH'].split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }.find { |p| File.executable?(p) } || name
  end

  def self.config
    keys = %w[GRAPH_HOST GRAPH_VERSION IG_USER_ID IG_ACCESS_TOKEN GITHUB_REPO GITHUB_BRANCH GITHUB_TOKEN SMTP_USER SMTP_PASS NOTIFY_EMAIL]
    cfg = keys.each_with_object({}) { |k, h| h[k] = ENV[k] if ENV[k] && !ENV[k].empty? }
    if File.exist?(CONFIG)
      raw = File.read(CONFIG)
      raw.lines.each do |l|
        next if l.strip.empty? || l.strip.start_with?('#')
        k, v = l.strip.split('=', 2)
        v = v.to_s.strip.gsub(/\A["']|["']\z/, '')
        cfg[k] ||= v unless v.empty? || v.start_with?('KLISTRA_IN', 'HAR_SKA')
      end
      cfg['IG_ACCESS_TOKEN'] ||= raw[/\b(EAA[A-Za-z0-9]{50,}|IG[A-Za-z0-9_\-]{50,})/, 1]
      cfg['GITHUB_TOKEN']    ||= raw[/\b(github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,})/, 1]
    end
    cfg['GITHUB_BRANCH'] = 'main' if cfg['GITHUB_BRANCH'].to_s.empty?
    cfg.compact
  end

  def self.http(method, url, body: nil, headers: {}, form: nil, limit: 5)
    uri = URI(url)
    klass = { get: Net::HTTP::Get, put: Net::HTTP::Put, post: Net::HTTP::Post, delete: Net::HTTP::Delete }[method]
    r = klass.new(uri)
    headers.each { |k, v| r[k] = v }
    r.set_form_data(form) if form
    r.body = body if body
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 900, open_timeout: 30) { |h| h.request(r) }
    if res.is_a?(Net::HTTPRedirection) && limit > 0
      return http(:get, res['location'], limit: limit - 1)
    end
    [res.code.to_i, res.body.to_s]
  end

  class GitHub
    def initialize(cfg)
      @repo = cfg['GITHUB_REPO']; @branch = cfg['GITHUB_BRANCH']; @tok = cfg['GITHUB_TOKEN']
      raise 'GITHUB_TOKEN/GITHUB_REPO saknas' unless @repo && @tok
    end
    attr_reader :repo

    def h(extra = {}) { 'Authorization' => "Bearer #{@tok}", 'Accept' => 'application/vnd.github+json' }.merge(extra) end
    def api(method, path, json = nil)
      c, b = Common.http(method, "https://api.github.com/repos/#{@repo}#{path}", body: json && JSON.generate(json),
                         headers: h(json ? { 'Content-Type' => 'application/json' } : {}))
      [c, (JSON.parse(b) rescue {})]
    end

    # → [content_string or nil, sha]
    def get_file(path)
      c, j = api(:get, "/contents/#{path}?ref=#{@branch}")
      return [nil, nil] unless c == 200
      [Base64.decode64(j['content']).force_encoding('UTF-8'), j['sha']]
    end

    def put_file(path, content, message)
      _, sha = get_file(path)
      c, j = api(:put, "/contents/#{path}", { message: message, content: Base64.strict_encode64(content), branch: @branch, sha: sha }.compact)
      raise "GitHub: kunde inte spara #{path} (#{c}): #{j['message']}" unless [200, 201].include?(c)
      j
    end

RELEASES = {
  RELEASE_TAG => ["Reels-bank (färdiga klipp)", "Färdigredigerade Reels som väntar på publicering. Skapas automatiskt."],
  SOURCES_TAG => ["Reels-källor (originalvideor + transkript)", "Originalvideor och transkript som Reels klipps från. Skapas automatiskt – radera inte."],
      BACKUP_TAG  => ["Säkerhetskopior", "Veckovisa säkerhetskopior av publiceringshistorik och innehållsbank. Skapas automatiskt."]
}.freeze

def release(tag = RELEASE_TAG)
  (@releases ||= {})[tag] ||= begin
    c, j = api(:get, "/releases/tags/#{tag}")
    if c != 200
      name, body = RELEASES.fetch(tag)
      c, j = api(:post, "/releases", { tag_name: tag, target_commitish: @branch, name: name, body: body })
      raise "GitHub: kunde inte skapa release #{tag} (#{c}): #{j["message"]}" unless c == 201
    end
    j
  end
end

def assets(tag = RELEASE_TAG)
  out = []; page = 1
  loop do
    c, j = api(:get, "/releases/#{release(tag)["id"]}/assets?per_page=100&page=#{page}")
    break unless c == 200 && j.is_a?(Array) && j.any?
    out.concat(j); page += 1
  end
  out
end

# streams the file, so even 1–2 GB source videos upload without loading into memory
def upload_asset(file, name, tag = RELEASE_TAG, type = "video/mp4")
  old = assets(tag).find { |a| a["name"] == name }
  api(:delete, "/releases/assets/#{old["id"]}") if old
  uri = URI("https://uploads.github.com/repos/#{@repo}/releases/#{release(tag)["id"]}/assets?name=#{URI.encode_www_form_component(name)}")
  req = Net::HTTP::Post.new(uri)
  h("Content-Type" => type, "Content-Length" => File.size(file).to_s).each { |k, v| req[k] = v }
  res = File.open(file, "rb") do |io|
    req.body_stream = io
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 3600, write_timeout: 3600, open_timeout: 30) { |x| x.request(req) }
  end
  j = (JSON.parse(res.body) rescue {})
  raise "GitHub: uppladdning av #{name} misslyckades (#{res.code}): #{j["message"]}" unless res.code.to_i == 201
  j
end

# streams to disk; follows the redirect to GitHub storage without sending the token there
def download_asset(asset_id, dest)
  url = "https://api.github.com/repos/#{@repo}/releases/assets/#{asset_id}"
  headers = h("Accept" => "application/octet-stream")
  5.times do
    uri = URI(url)
    req = Net::HTTP::Get.new(uri); headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 3600, open_timeout: 30) do |x|
      x.request(req) do |res|
        if res.is_a?(Net::HTTPRedirection) then url = res["location"]; headers = {}
        elsif res.code.to_i == 200
          File.open(dest, "wb") { |f| res.read_body { |chunk| f.write(chunk) } }
          return dest
        else raise "GitHub: kunde inte hämta fil (#{res.code})"
        end
      end
    end
  end
  raise "GitHub: för många omdirigeringar"
end
  end

  AR_DIGITS = '٠١٢٣٤٥٦٧٨٩'
  def self.ar(n) n.to_s.tr('0123456789', AR_DIGITS) end

  # Arabic caption: only verbatim verse text + verifiable facts. Nothing invented.
  def self.caption(clip, verses_text)
    rng = clip['from'] == clip['to'] ? "الآية #{ar(clip['from'])}" : "الآيات #{ar(clip['from'])}–#{ar(clip['to'])}"
    body = verses_text.map { |a, t| "#{t} ﴿#{ar(a)}﴾" }.join(' ')
    body = verses_text.first.then { |a, t| "#{t} ﴿#{ar(a)}﴾ …" } if body.size > 1200
    lines = []
    lines << '﴿ ' + body + ' ﴾'
    lines << ''
    lines << "📖 سورة #{clip['sura_name']} — #{rng}"
    lines << "🎙️ بصوت #{clip['reciter']}" unless clip['reciter'].to_s.empty?
    lines << ''
    lines << 'استمع بقلبك وتدبّر 🤍'
    lines << ''
    lines << "المصدر: #{clip['channel']} — #{clip['source_url']}" if clip['channel']
    lines << 'نص الآيات: مشروع تنزيل tanzil.net'
    lines << ''
    tags = %w[#قرآن #القرآن_الكريم #تلاوة #تلاوة_خاشعة #تلاوات #راحة_نفسية #نبض_السنة #quran #quranrecitation]
    tags.insert(5, "#سورة_#{clip['sura_name'].tr(' ', '_')}")
    if (r = clip['reciter'].to_s.sub(/\Aالشيخ\s+/, '').sub(/\Aد\.\s*/, '').strip) != ''
      tags.insert(6, '#' + r.tr(' ', '_'))
    end
    lines << tags.join(' ')
    lines.join("\n")
  end
end
