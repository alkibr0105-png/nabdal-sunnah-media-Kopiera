#!/usr/bin/env ruby
# Reels production (runs in the cloud on GitHub Actions, or on the Mac). Publishing: reels/publish.rb.
#
#   ruby reels/reelmaker.rb run              # full cycle: new links → download → transcribe → find clips → render → upload to bank
#   ruby reels/reelmaker.rb local <url>      # test locally: analyse + render clips into out/reels-test, upload nothing
#   ruby reels/reelmaker.rb status           # show the bank
require 'fileutils'
require 'time'
require 'etc'
require 'open3'
require_relative 'common'
require_relative 'render'

ROOT    = Common::ROOT
YTDLP   = Common.tool("yt-dlp", "YTDLP", "bin/yt-dlp")
FFMPEG  = Render::FFMPEG
WHISPER = Common.tool("whisper-cli", "WHISPER", "tools/whisper.cpp/build/bin/whisper-cli")
MODEL   = ENV["WHISPER_MODEL"].to_s.empty? ? File.join(ROOT, "tools/models/ggml-large-v3-turbo-q5_0.bin") : ENV["WHISPER_MODEL"]
THREADS = [(Etc.nprocessors rescue 4), 8].min.to_s
SOURCES = File.join(ROOT, "sources")
WORK    = File.join(ROOT, "work")
LOCK    = File.join(WORK, ".lock")
WHERE   = Common::CLOUD ? "cloud" : "mac"

def log(msg) puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"; $stdout.flush end

def vid_of(url)
  url[%r{(?:v=|youtu\.be/|shorts/|live/)([A-Za-z0-9_-]{11})}, 1]
end

# links.txt: one YouTube link per line. Optional: "<link> | <reciter name>". Lines starting with # are ignored.
def parse_links(txt)
  txt.to_s.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }.map do |l|
    url, name = l.split('|', 2).map(&:strip)
    v = vid_of(url) or next
    { vid: v, url: "https://www.youtube.com/watch?v=#{v}", reciter: name }
  end.compact.uniq { |x| x[:vid] }
end

def reciter_from_title(t)
  m = t.to_s.match(/(?:ال|لل)?شيخ\s+(?:د\.\s*)?(\p{Arabic}+(?:\s+(?:بن|ابن)\s+\p{Arabic}+|\s+\p{Arabic}+)?)/)
  m && "الشيخ #{m[1]}"
end

def gh_client() $gh ||= Common::GitHub.new(Common.config) end
def source_asset(name) gh_client.assets(Common::SOURCES_TAG).find { |x| x["name"] == name } end

# 1) local copy  2) cloud storage (release "reels-sources")  3) YouTube
def download(vid, url)
  mp4 = File.join(SOURCES, "#{vid}.mp4")
  FileUtils.mkdir_p(SOURCES)
  unless File.size?(mp4)
    if (a = source_asset("#{vid}.mp4"))
      log "Hämtar originalvideon från molnlagringen…"
      gh_client.download_asset(a["id"], mp4)
      (i = source_asset("#{vid}.info.json")) && gh_client.download_asset(i["id"], File.join(SOURCES, "#{vid}.info.json"))
    else
      Render.run!(YTDLP, "--no-warnings", "--no-progress", "--ffmpeg-location", File.dirname(FFMPEG),
                  "-f", "bv*[height<=720][ext=mp4]+ba[ext=m4a]/b[height<=720]", "--merge-output-format", "mp4",
                  "--write-info-json", "-o", File.join(SOURCES, "%(id)s.%(ext)s"), url)
    end
  end
  raise "nedladdningen gav ingen fil" unless File.size?(mp4)
  store_source(vid, mp4)
  mp4
end

# keep every original + metadata in cloud storage (once)
def store_source(vid, mp4)
  return if source_asset("#{vid}.mp4")
  log "Sparar originalvideon i molnlagringen…"
  gh_client.upload_asset(mp4, "#{vid}.mp4", Common::SOURCES_TAG)
  info = File.join(SOURCES, "#{vid}.info.json")
  if File.exist?(info)
    j = JSON.parse(File.read(info))
    slim = j.slice("id", "title", "channel", "uploader", "channel_url", "uploader_url", "duration", "upload_date", "webpage_url")
    File.write(info, JSON.generate(slim))
    gh_client.upload_asset(info, "#{vid}.info.json", Common::SOURCES_TAG, "application/json")
  end
end

def transcribe(vid, mp4)
  work = File.join(WORK, vid); FileUtils.mkdir_p(work)
  json = File.join(work, "words.json")
  return [work, json] if File.size?(json)
  if (a = source_asset("#{vid}.words.json"))
    gh_client.download_asset(a["id"], json)
    return [work, json] if File.size?(json)
  end
  wav = File.join(work, "audio.wav")
  Render.run!(FFMPEG, "-v", "error", "-y", "-i", mp4, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav) unless File.size?(wav)
  Render.run!(WHISPER, "-m", MODEL, "-l", "ar", "-t", THREADS, "-ml", "1", "-sow", "-oj", "-np", "-of", File.join(work, "words"),
              "--prompt", "بسم الله الرحمن الرحيم", "-f", wav)
  gh_client.upload_asset(json, "#{vid}.words.json", Common::SOURCES_TAG, "application/json")
  File.delete(wav)
  [work, json]
end

def info(vid)
  f = File.join(SOURCES, "#{vid}.info.json")
  j = File.exist?(f) ? JSON.parse(File.read(f)) : {}
  if j.empty?
    c, b = Common.http(:get, "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=#{vid}") rescue [0, ""]
    o = (JSON.parse(b) rescue {})
    j = { 'title' => o['title'], 'channel' => o['author_name'], 'channel_url' => o['author_url'] } if c == 200
  end
  { title: j['title'], channel: j['channel'] || j['uploader'], channel_url: j['channel_url'] || j['uploader_url'], duration: j['duration'] }
end

def clip_record(vid, src, c, meta)
  f = c[:run].first; l = c[:run].last
  {
    'id' => "#{vid}-#{f[:s]}-#{f[:a]}-#{l[:a]}-#{f[:t0].to_i}", 'vid' => vid,
    'sura' => f[:s], 'sura_name' => Quran.sura_name(f[:s]), 'from' => f[:a], 'to' => l[:a],
    'reciter' => meta[:reciter], 'channel' => src['channel'], 'source_url' => "https://youtu.be/#{vid}?t=#{f[:t0].to_i}",
    'score' => c[:score].round(2), 'status' => 'pending'
  }
end

def overlaps?(a, b)
  a['reciter'] == b['reciter'] && a['sura'] == b['sura'] && a['from'] <= b['to'] && b['from'] <= a['to']
end

def analyse(vid, mp4)
  work, json = transcribe(vid, mp4)
  wd = Analyze.load_words(json)
  passages = Quran.align(wd)
  [work, wd, Analyze.candidates(wd, passages)]
end

def verses_text(c) c[:run].map { |v| [v[:a], Quran.uthmani[[v[:s], v[:a]]]] } end

# ---------------------------------------------------------------- local test
def local_test(url, max = 3)
  vid = vid_of(url) or abort 'Ogiltig YouTube-länk'
  mp4 = download(vid, url)
  meta = info(vid)
  reciter = reciter_from_title(meta[:title])
  work, wd, cands = analyse(vid, mp4)
  log "#{cands.size} klipp hittade i #{vid} (#{meta[:title]})"
  out = File.join(ROOT, 'out', 'reels-test'); FileUtils.mkdir_p(out)
  cands.sort_by { |c| -c[:score] }.first(max).each do |c|
    rec = clip_record(vid, { 'channel' => meta[:channel] }, c, { reciter: reciter })
    file = File.join(out, "#{rec['id']}.mp4")
    r = Render.clip(mp4, work, c, wd, { reciter: reciter }, file)
    File.write(file.sub(/\.mp4\z/, '.txt'), Common.caption(rec, verses_text(c)))
    log "✓ #{File.basename(file)}  #{rec['sura_name']} #{rec['from']}–#{rec['to']}  #{r[:dur]}s  (score #{rec['score']})"
  end
end

# ---------------------------------------------------------------- full cycle
def full_run
  FileUtils.mkdir_p(WORK)
  lock = File.open(LOCK, File::RDWR | File::CREAT)
  return log('Körs redan, hoppar över.') unless lock.flock(File::LOCK_EX | File::LOCK_NB)

  gh = gh_client
  # Only ONE producer at a time (prevents duplicate clips during the move to the cloud).
  owner = (JSON.parse(gh.get_file('reels/config.json').first || '{}')['producer'] || 'mac') rescue 'mac'
  return log("Producent är '#{owner}', inte '#{WHERE}' – hoppar över.") unless owner == WHERE || ENV['FORCE_PRODUCER'] == '1'
  deadline = Time.now + (ENV['REEL_BUDGET_MIN'] || '100000').to_i * 60
  links_txt, = gh.get_file('reels/links.txt')
  bank_txt, = gh.get_file('reels/bank.json')
  bank = bank_txt ? JSON.parse(bank_txt) : { 'sources' => {}, 'clips' => [], 'errors' => [] }
  published = (gh.get_file('reels/published.log').first || '').lines.map { |l| l.split("\t")[1] }.compact
  save = lambda do |msg|
    bank['updated_at'] = Time.now.utc.iso8601
    gh.put_file('reels/bank.json', JSON.pretty_generate(bank) + "\n", msg)
  end
  error = lambda do |where, e|
    log "FEL #{where}: #{e.message}"
    bank['errors'] << { 'at' => Time.now.utc.iso8601, 'where' => where, 'message' => e.message[0, 400] }
    bank['errors'] = bank['errors'].last(30)
  end

  # 1. new links → analyse
  parse_links(links_txt).each do |lnk|
    break log("Tidsbudgeten slut – fortsätter nästa körning.") if Time.now > deadline
    vid = lnk[:vid]
    src = bank['sources'][vid] ||= { 'url' => lnk[:url], 'added_at' => Time.now.utc.iso8601, 'status' => 'new' }
    next if src['status'] == 'analyzed'
    next if src['status'] == 'failed' && src['attempts'].to_i >= 3
    begin
      log "Ny video: #{vid}"
      mp4 = download(vid, lnk[:url])
      meta = info(vid)
      src.merge!('title' => meta[:title], 'channel' => meta[:channel], 'channel_url' => meta[:channel_url], 'duration' => meta[:duration])
      src['reciter'] = lnk[:reciter] || reciter_from_title(meta[:title])
      log 'Transkriberar och söker verser…'
      _, _, cands = analyse(vid, mp4)
      added = 0
      cands.each do |c|
        rec = clip_record(vid, src, c, { reciter: src['reciter'] })
        next if bank['clips'].any? { |x| x['id'] == rec['id'] || (x['vid'] != vid && overlaps?(x, rec)) }
        bank['clips'] << rec; added += 1
      end
      src.merge!('status' => 'analyzed', 'analyzed_at' => Time.now.utc.iso8601, 'clips_found' => added)
      src.delete('error')
      log "#{added} klipp hittade"
    rescue StandardError => e
      if e.message =~ /not a bot|Sign in to confirm|HTTP Error 429/i
        # YouTube blocks cloud servers. Never work around it: wait for the Mac collector or an uploaded file.
        src['status'] = 'waiting_video'
        src['error'] = 'YouTube blockerar molnet. Videon hämtas nästa gång Macen är på, eller ladda upp filen till releasen reels-sources som ' + "#{vid}.mp4"
        log "Väntar på video #{vid} (YouTube blockerar molnet)"
      else
        src['status'] = 'failed'; src['attempts'] = src['attempts'].to_i + 1; src['error'] = e.message[0, 300]
        error.("video #{vid}", e)
      end
    end
    save.("bank: analys av #{vid}")
  end

  # 2. render pending clips → upload to the bank (release assets)
  cache = {}
  bank['clips'].select { |c| c['status'] == 'pending' }.each_with_index do |rec, n|
    break log("Tidsbudgeten slut – fortsätter nästa körning.") if Time.now > deadline
    vid = rec['vid']
    begin
      mp4 = File.join(SOURCES, "#{vid}.mp4")
      mp4 = download(vid, bank['sources'][vid]['url']) unless File.size?(mp4)
      cache[vid] ||= analyse(vid, mp4)
      work, wd, cands = cache[vid]
      c = cands.find { |x| clip_record(vid, {}, x, { reciter: rec['reciter'] })['id'] == rec['id'] }
      raise 'klippet hittades inte vid ny analys' unless c
      file = File.join(WORK, vid, "#{rec['id']}.mp4")
      log "Renderar #{rec['id']}…"
      r = Render.clip(mp4, work, c, wd, { reciter: rec['reciter'] }, file)
      rec['caption'] = Common.caption(rec, verses_text(c))
      rec['duration'] = r[:dur]
      asset = gh.upload_asset(file, "#{rec['id']}.mp4")
      rec.merge!('asset_id' => asset['id'], 'asset' => asset['name'], 'status' => 'ready', 'ready_at' => Time.now.utc.iso8601)
      File.delete(file)
    rescue StandardError => e
      rec['status'] = 'failed'; rec['error'] = e.message[0, 300]
      error.("klipp #{rec['id']}", e)
    end
    save.("bank: #{rec['id']} #{rec['status']}") if (n % 5 == 4) || rec['status'] != 'ready'
  end
  save.('bank: uppdaterad') if bank['clips'].any? { |c| c['status'] == 'ready' }
  ready = bank['clips'].count { |c| c['status'] == 'ready' && !published.include?(c['id']) }
  log "Klart. Färdiga klipp i banken som väntar: #{ready}"
end

def status
  cfg = Common.config
  gh = Common::GitHub.new(cfg)
  bank = JSON.parse(gh.get_file('reels/bank.json').first || '{"sources":{},"clips":[]}')
  published = (gh.get_file('reels/published.log').first || '').lines.map { |l| l.split("\t")[1] }
  bank['sources'].each { |v, s| puts "#{v}  #{s['status']}  #{s['clips_found']} klipp  #{s['title']}  #{s['error']}" }
  bank['clips'].group_by { |c| published.include?(c['id']) ? 'published' : c['status'] }.each { |k, v| puts "#{k}: #{v.size}" }
end

case ARGV[0]
when 'run' then full_run
when 'collect'
  # Mac collector: fetch videos for new links (YouTube blocks cloud servers) and put them in cloud storage. Produces and publishes nothing.
  parse_links(gh_client.get_file('reels/links.txt').first).each do |l|
    next if source_asset("#{l[:vid]}.mp4")
    begin
      log "Hämtar #{l[:vid]} till molnlagringen…"
      download(l[:vid], l[:url])
    rescue StandardError => e
      log "FEL #{l[:vid]}: #{e.message[0, 200]}"
    end
  end
  log "Insamling klar."
when 'local' then local_test(ARGV[1], (ARGV[2] || 3).to_i)
when 'status' then status
when 'analyse'
  ARGV[1..].each do |u|
    v = vid_of(u) || u
    t = Time.now
    _, _, cands = analyse(v, download(v, "https://www.youtube.com/watch?v=#{v}"))
    log "#{v}: #{cands.size} klipp (#{(Time.now - t).round}s)"
    cands.each { |c| f = c[:run].first; l = c[:run].last; puts "  #{Quran.sura_name(f[:s])} #{f[:a]}–#{l[:a]}  #{c[:dur].round}s  score #{c[:score].round(1)}  @#{f[:t0].round}s" }
  end
when 'cloudtest'
  # Cloud self-test: tools, YouTube access (normal request, no workarounds), one rendered clip. Writes nothing to the bank.
  ok = true
  { "ffmpeg" => [FFMPEG, "-version"], "chrome" => [Render::CHROME, "--version"], "whisper" => [WHISPER, "--help"], "yt-dlp" => [YTDLP, "--version"] }.each do |n, cmd|
    o, st = Open3.capture2e(*cmd) rescue ["saknas", nil]
    log "#{st&.success? ? "✓" : "✗"} #{n}: #{o.lines.first.to_s.strip[0, 80]}"
    ok &&= st&.success? || n == "whisper"
  end
  log "✓ Whisper-modell: #{File.size?(MODEL).to_i / 1_000_000} MB" if File.size?(MODEL)
  first = parse_links(gh_client.get_file("reels/links.txt").first).first
  if first
    o, st = Open3.capture2e(YTDLP, "--no-warnings", "--simulate", "--print", "title", first[:url])
    log(st.success? ? "✓ YouTube svarar från molnet: #{o.strip[0, 60]}" : "✗ YouTube blockerar molnservern: #{o.lines.last.to_s.strip[0, 160]}")
  end
  vid = %w[_6pTp5V_R3A pG7Z2_F4HCc].find { |v| source_asset("#{v}.words.json") }
  mp4 = download(vid, "https://www.youtube.com/watch?v=#{vid}")
  meta = info(vid)
  work, wd, cands = analyse(vid, mp4)
  log "✓ Versanalys: #{cands.size} klipp i #{vid}"
  c = cands.max_by { |x| x[:score] }
  out = File.join(ROOT, "out", "cloudtest"); FileUtils.mkdir_p(out)
  rec = clip_record(vid, { "channel" => meta[:channel] }, c, { reciter: reciter_from_title(meta[:title]) })
  t = Time.now
  r = Render.clip(mp4, work, c, wd, { reciter: rec["reciter"] }, File.join(out, "#{rec["id"]}.mp4"))
  File.write(File.join(out, "#{rec["id"]}.txt"), Common.caption(rec, verses_text(c)))
  log "✓ Renderat i molnet: #{rec["id"]} (#{r[:dur]} s) på #{(Time.now - t).round} s"
  exit(ok ? 0 : 1)
when 'migrate'
  # copy local originals, metadata and transcripts to cloud storage (release reels-sources); safe to run again
  Dir[File.join(SOURCES, '*.mp4')].sort.each do |mp4|
    vid = File.basename(mp4, '.mp4')
    store_source(vid, mp4)
    w = File.join(WORK, vid, 'words.json')
    if File.size?(w) && !source_asset("#{vid}.words.json")
      gh_client.upload_asset(w, "#{vid}.words.json", Common::SOURCES_TAG, 'application/json')
    end
    log "#{vid}: video #{source_asset("#{vid}.mp4") ? '✓' : '–'}  transkript #{source_asset("#{vid}.words.json") ? '✓' : 'väntar'}"
  end
when 'make-one'
  # ruby reels/reelmaker.rb make-one <vid> <sura> <from_aya>  → render one clip and put it in the bank as ready
  vid, sura, from = ARGV[1], ARGV[2].to_i, ARGV[3].to_i
  gh = Common::GitHub.new(Common.config)
  bank = JSON.parse(gh.get_file('reels/bank.json').first || '{"sources":{},"clips":[],"errors":[]}')
  url = "https://www.youtube.com/watch?v=#{vid}"
  mp4 = download(vid, url)
  meta = info(vid)
  src = bank['sources'][vid] ||= { 'url' => url, 'added_at' => Time.now.utc.iso8601, 'status' => 'new' }
  src.merge!('title' => meta[:title], 'channel' => meta[:channel], 'channel_url' => meta[:channel_url], 'duration' => meta[:duration])
  src['reciter'] ||= reciter_from_title(meta[:title])
  work, wd, cands = analyse(vid, mp4)
  c = cands.find { |x| x[:run].first[:s] == sura && x[:run].first[:a] == from } or abort 'Klippet finns inte bland kandidaterna'
  rec = clip_record(vid, src, c, { reciter: src['reciter'] })
  file = File.join(WORK, vid, "#{rec['id']}.mp4")
  r = Render.clip(mp4, work, c, wd, { reciter: rec['reciter'] }, file)
  rec['caption'] = Common.caption(rec, verses_text(c))
  rec['duration'] = r[:dur]
  asset = gh.upload_asset(file, "#{rec['id']}.mp4")
  rec.merge!('asset_id' => asset['id'], 'asset' => asset['name'], 'status' => 'ready', 'ready_at' => Time.now.utc.iso8601)
  bank['clips'].reject! { |x| x['id'] == rec['id'] }
  bank['clips'] << rec
  bank['updated_at'] = Time.now.utc.iso8601
  gh.put_file('reels/bank.json', JSON.pretty_generate(bank) + "\n", "bank: #{rec['id']} ready")
  FileUtils.cp(file, File.join(ROOT, 'out', 'reels-test'))
  log "✓ #{rec['id']} (#{r[:dur]} s) ligger i banken"
else puts File.read(__FILE__)[/^# Reels.*?(?=^require)/m]
end
