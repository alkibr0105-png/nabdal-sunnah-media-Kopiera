#!/usr/bin/env ruby
# Reels production (runs on the Mac). Publishing happens on GitHub Actions (reels/publish.rb).
#
#   ruby reels/reelmaker.rb run              # full cycle: new links → download → transcribe → find clips → render → upload to bank
#   ruby reels/reelmaker.rb local <url>      # test locally: analyse + render clips into out/reels-test, upload nothing
#   ruby reels/reelmaker.rb status           # show the bank
require 'fileutils'
require 'time'
require_relative 'common'
require_relative 'render'

ROOT    = Common::ROOT
BIN     = File.join(ROOT, 'bin')
WHISPER = File.join(ROOT, 'tools/whisper.cpp/build/bin/whisper-cli')
MODEL   = File.join(ROOT, 'tools/models/ggml-large-v3-turbo-q5_0.bin')
SOURCES = File.join(ROOT, 'sources')
WORK    = File.join(ROOT, 'work')
LOCK    = File.join(WORK, '.lock')

def log(msg) puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"; $stdout.flush end

def vid_of(url)
  url[%r{(?:v=|youtu\.be/|shorts/|live/)([A-Za-z0-9_-]{11})}, 1]
end

# links.txt: one YouTube link per line. Optional: "<link> | <reciter name>". Lines starting with # are ignored.
def parse_links(txt)
  txt.to_s.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }.filter_map do |l|
    url, name = l.split('|', 2).map(&:strip)
    v = vid_of(url) or next
    { vid: v, url: "https://www.youtube.com/watch?v=#{v}", reciter: name }
  end.uniq { |x| x[:vid] }
end

def reciter_from_title(t)
  m = t.to_s.match(/(?:ال|لل)?شيخ\s+(?:د\.\s*)?(\p{Arabic}+(?:\s+(?:بن|ابن)\s+\p{Arabic}+|\s+\p{Arabic}+)?)/)
  m && "الشيخ #{m[1]}"
end

def download(vid, url)
  mp4 = File.join(SOURCES, "#{vid}.mp4")
  return mp4 if File.size?(mp4)
  FileUtils.mkdir_p(SOURCES)
  Render.run!(File.join(BIN, 'yt-dlp'), '--no-warnings', '--no-progress', '--ffmpeg-location', BIN,
              '-f', 'bv*[height<=720][ext=mp4]+ba[ext=m4a]/b[height<=720]', '--merge-output-format', 'mp4',
              '--write-info-json', '-o', File.join(SOURCES, '%(id)s.%(ext)s'), url)
  raise 'nedladdningen gav ingen fil' unless File.size?(mp4)
  mp4
end

def transcribe(vid, mp4)
  work = File.join(WORK, vid); FileUtils.mkdir_p(work)
  json = File.join(work, 'words.json')
  return [work, json] if File.size?(json)
  wav = File.join(work, 'audio.wav')
  Render.run!(File.join(BIN, 'ffmpeg'), '-v', 'error', '-y', '-i', mp4, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', wav) unless File.size?(wav)
  Render.run!(WHISPER, '-m', MODEL, '-l', 'ar', '-t', '8', '-ml', '1', '-sow', '-oj', '-np', '-of', File.join(work, 'words'),
              '--prompt', 'بسم الله الرحمن الرحيم', '-f', wav)
  [work, json]
end

def info(vid)
  f = File.join(SOURCES, "#{vid}.info.json")
  j = File.exist?(f) ? JSON.parse(File.read(f)) : {}
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

  cfg = Common.config
  gh = Common::GitHub.new(cfg)
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
      src['status'] = 'failed'; src['attempts'] = src['attempts'].to_i + 1; src['error'] = e.message[0, 300]
      error.("video #{vid}", e)
    end
    save.("bank: analys av #{vid}")
  end

  # 2. render pending clips → upload to the bank (release assets)
  cache = {}
  bank['clips'].select { |c| c['status'] == 'pending' }.each_with_index do |rec, n|
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
else puts File.read(__FILE__)[/^# Reels.*?(?=^require)/m]
end
