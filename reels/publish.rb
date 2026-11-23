#!/usr/bin/env ruby
# Reels publishing + daily report (runs on GitHub Actions; the Mac can be off).
#
#   ruby reels/publish.rb slot        # called by the schedule: waits for 12:00 / 19:00 Swedish time, publishes the next clip from the bank
#   ruby reels/publish.rb slot --dry-run   # same, but only shows what would be published
#   ruby reels/publish.rb report      # send the daily report now
#
# State files in the repo (written through the GitHub API, so runs never conflict):
#   reels/bank.json      — written by the Mac: analysed videos and finished clips
#   reels/published.log  — written here: date, clip id, media id, slot, permalink
#   reels/errors.log     — written here: publishing errors
#   reels/config.json    — {"publish": true|false}  master switch
require 'open3'
require 'tmpdir'
require 'time'
require_relative 'common'

ENV['TZ'] = 'Europe/Stockholm'   # Swedish local time, summer/winter time handled by the OS time zone database
SLOTS = { 'noon' => 12, 'evening' => 19 }.freeze
DRY = ARGV.include?('--dry-run')

def log(m) puts "[#{Time.now.strftime('%F %T %Z')}] #{m}"; $stdout.flush end

CFG = Common.config
GH  = Common::GitHub.new(CFG)

def read_lines(path) (GH.get_file(path).first || '').lines.map(&:chomp).reject(&:empty?) end
def append_line(path, line, msg)
  content = (GH.get_file(path).first || '')
  content += "\n" unless content.empty? || content.end_with?("\n")
  GH.put_file(path, content + line + "\n", msg)
end

def bank() JSON.parse(GH.get_file('reels/bank.json').first || '{"sources":{},"clips":[],"errors":[]}') end
def published() read_lines('reels/published.log').map { |l| l.split("\t") } end
def publish_enabled?() (JSON.parse(GH.get_file('reels/config.json').first || '{}')['publish'] == true) rescue false end

def record_error(slot, msg)
  log "FEL: #{msg}"
  append_line('reels/errors.log', [Time.now.strftime('%F %H:%M'), slot, msg.to_s.gsub(/\s+/, ' ')[0, 400]].join("\t"), "reels: fel #{slot}") unless DRY
end

def next_clip(b, pub)
  done = pub.map { |r| r[1] }
  ready = b['clips'].select { |c| c['status'] == 'ready' && c['asset_id'] && !done.include?(c['id']) }
  return nil if ready.empty?
  last = b['clips'].find { |c| c['id'] == done.last }
  per_vid = Hash.new(0); pub.each { |r| v = b['clips'].find { |c| c['id'] == r[1] }; per_vid[v['vid']] += 1 if v }
  # spread sources and surahs: avoid repeating the last video/surah, prefer the least-used video, then the best clip
  ready.min_by do |c|
    [(last && c['vid'] == last['vid'] && ready.any? { |x| x['vid'] != last['vid'] }) ? 1 : 0,
     (last && c['sura'] == last['sura']) ? 1 : 0, per_vid[c['vid']], -c['score'].to_f, c['id']]
  end
end

def graph
  tok = CFG['IG_ACCESS_TOKEN'].to_s
  host = !CFG['GRAPH_HOST'].to_s.empty? ? CFG['GRAPH_HOST'] : (tok.start_with?('EAA') ? 'graph.facebook.com' : 'graph.instagram.com')
  ver = CFG['GRAPH_VERSION'].to_s.empty? ? 'v23.0' : CFG['GRAPH_VERSION']
  ["https://#{host}/#{ver}", ver, tok]
end

def ig(method, url, form: nil, headers: {}, body: nil)
  c, b = Common.http(method, url, form: form, headers: headers, body: body)
  [c, (JSON.parse(b) rescue { 'raw' => b })]
end

def publish_reel(clip, video)
  base, ver, tok = graph
  raise 'IG_ACCESS_TOKEN saknas' if tok.empty?
  c, r = ig(:post, "#{base}/#{CFG['IG_USER_ID']}/media", form: { media_type: 'REELS', upload_type: 'resumable', caption: clip['caption'],
            share_to_feed: 'true', thumb_offset: '3500', access_token: tok })
  raise "Kunde inte skapa Reel (#{c}): #{r.dig('error', 'message')}" unless c == 200 && r['id']
  container = r['id']
  bytes = File.binread(video)
  c, r = ig(:post, r['uri'] || "https://rupload.facebook.com/ig-api-upload/#{ver}/#{container}",
            headers: { 'Authorization' => "OAuth #{tok}", 'offset' => '0', 'file_size' => bytes.bytesize.to_s, 'Content-Type' => 'application/octet-stream' }, body: bytes)
  raise "Uppladdning till Instagram misslyckades (#{c}): #{r.dig('debug_info', 'message') || r.dig('error', 'message') || r['raw']}" unless c == 200
  status = nil
  60.times do
    _, s = ig(:get, "#{base}/#{container}?fields=status_code,status&access_token=#{URI.encode_www_form_component(tok)}")
    status = s['status_code']
    break if status == 'FINISHED'
    raise "Instagram avvisade videon: #{s['status']}" if %w[ERROR EXPIRED].include?(status)
    sleep 10
  end
  raise "Videon blev inte klar hos Instagram (status: #{status})" unless status == 'FINISHED'
  c, r = ig(:post, "#{base}/#{CFG['IG_USER_ID']}/media_publish", form: { creation_id: container, access_token: tok })
  raise "Publiceringen misslyckades (#{c}): #{r.dig('error', 'message')}" unless c == 200 && r['id']
  media = r['id']
  _, p = ig(:get, "#{base}/#{media}?fields=permalink&access_token=#{URI.encode_www_form_component(tok)}")
  [media, p['permalink'].to_s]
end

# Which slot is this run for? Runs are scheduled ahead of time; wait until the exact local time.
def current_slot
  now = Time.now
  SLOTS.each do |name, hour|
    target = Time.new(now.year, now.month, now.day, hour, 0, 0)
    diff = target - now
    return [name, target] if diff.between?(-3 * 3600, 80 * 60)
  end
  nil
end

def run_slot
  slot, target = current_slot
  if ARGV.include?('--now') then slot, target = ['manual', Time.now] end
  return log('Ingen publiceringstid just nu (12:00 eller 19:00 svensk tid). Avslutar.') unless slot
  today = Time.now.strftime('%F')
  if published.any? { |r| r[0] == today && r[3] == slot } && slot != 'manual'
    return log("Redan publicerat för #{slot} idag.")
  end
  if (wait = target - Time.now) > 0 && !DRY
    log "Väntar #{(wait / 60).round} min till #{target.strftime('%H:%M')} svensk tid…"
    sleep wait
  end
  pub = published
  return log("Redan publicerat för #{slot} idag (annan körning).") if pub.any? { |r| r[0] == today && r[3] == slot } && slot != 'manual'
  b = bank
  one = ARGV.include?('--clip') ? ARGV[ARGV.index('--clip') + 1] : nil
  clip = one ? b['clips'].find { |c| c['id'] == one && c['status'] == 'ready' } : next_clip(b, pub)
  abort "Klippet #{one} finns inte som färdigt i banken" if one && !clip
  abort "Klippet #{one} är redan publicerat" if one && pub.any? { |r| r[1] == one }
  unless clip
    pending = b['clips'].count { |c| c['status'] == 'pending' }
    record_error(slot, pending > 0 ? "Inga färdiga Reels ännu – #{pending} klipp väntar på redigering på Macen (slå på datorn)." :
                                     'Banken är tom – inga färdiga Reels att publicera. Lägg till fler YouTube-länkar.')
    return
  end
  log "Nästa klipp: #{clip['id']} – سورة #{clip['sura_name']} #{clip['from']}–#{clip['to']}"
  if DRY
    puts "\n--- Beskrivning ---\n#{clip['caption']}\n"
    return
  end
  # a one-off, explicitly named clip (--clip ID) may be published while the schedule is still switched off
  unless publish_enabled? || one
    log 'Publicering är avstängd (reels/config.json → "publish": false). Inget publicerat.'
    return
  end
  video = File.join(Dir.tmpdir, clip['asset'])
  GH.download_asset(clip['asset_id'], video)
  media, link = publish_reel(clip, video)
  append_line('reels/published.log', [today, clip['id'], media, slot, link].join("\t"), "reels: publicerad #{clip['id']}")
  log "✓ Publicerad: #{link}"
rescue StandardError => e
  record_error(slot || 'okänd', e.message)
  raise
end

def send_email(subject, body)
  user, pass, to = CFG.values_at('SMTP_USER', 'SMTP_PASS', 'NOTIFY_EMAIL')
  if [user, pass, to].any? { |v| v.to_s.empty? } then log 'E-post: inte konfigurerad, hoppar över.'; return false end
  msg = <<~MAIL.gsub("\n", "\r\n")
    From: =?UTF-8?B?#{Base64.strict_encode64('نبض السنة – bot')}?= <#{user}>
    To: <#{to}>
    Subject: =?UTF-8?B?#{Base64.strict_encode64(subject)}?=
    Date: #{Time.now.strftime('%a, %d %b %Y %H:%M:%S %z')}
    MIME-Version: 1.0
    Content-Type: text/plain; charset=UTF-8
    Content-Transfer-Encoding: base64

    #{Base64.encode64(body)}
  MAIL
  f = File.join(Dir.tmpdir, "reel-mail-#{Process.pid}.eml"); File.write(f, msg)
  netrc = File.join(Dir.tmpdir, "reel-netrc-#{Process.pid}")
  File.write(netrc, "machine smtp.gmail.com login #{user} password #{pass.delete(' ')}\n"); File.chmod(0600, netrc)
  out, st = Open3.capture2e('curl', '-sS', '--ssl-reqd', '--url', 'smtps://smtp.gmail.com:465', '--netrc-file', netrc,
                            '--mail-from', user, '--mail-rcpt', to, '--upload-file', f)
  File.delete(f, netrc)
  log(st.success? ? 'Rapport skickad.' : "E-post misslyckades: #{out.strip}")
  st.success?
end

def report
  today = Time.now.strftime('%F')
  b = bank; pub = published
  todays = pub.select { |r| r[0] == today }
  done = pub.map { |r| r[1] }
  ready = b['clips'].count { |c| c['status'] == 'ready' && !done.include?(c['id']) }
  pending = b['clips'].count { |c| c['status'] == 'pending' }
  errs = read_lines('reels/errors.log').select { |l| l.start_with?(today) }.map { |l| l.split("\t", 3).values_at(0, 2).join(' – ') }
  since = Time.now - 24 * 3600
  errs += b['errors'].to_a.select { |e| (Time.parse(e['at']) rescue Time.at(0)) > since }.map { |e| "Mac (#{e['where']}): #{e['message']}" }
  hadith = read_lines('posted.log').find { |l| l.start_with?(today) }
  lines = ["Daglig rapport – #{today}", '']
  lines << "Publicerade Reels idag: #{todays.size} av 2"
  todays.each do |r|
    c = b['clips'].find { |x| x['id'] == r[1] } || {}
    lines << "  • #{r[3] == 'noon' ? '12:00' : r[3] == 'evening' ? '19:00' : r[3]}  سورة #{c['sura_name']} #{c['from']}–#{c['to']} #{c['reciter']}"
    lines << "    #{r[4]}"
  end
  lines << ''
  lines << "Färdiga Reels som väntar i banken: #{ready}#{ready < 6 ? '  ⚠️ snart slut – lägg till fler YouTube-länkar' : ''}"
  lines << "Klipp som väntar på redigering (Macen): #{pending}" if pending > 0
  lines << "Dagens hadith: #{hadith ? 'publicerad ✓' : 'inte publicerad'}"
  lines << ''
  lines << (errs.empty? ? 'Fel och tekniska problem: inga ✓' : "Fel och tekniska problem (#{errs.size}):")
  errs.each { |e| lines << "  • #{e}" }
  lines << '' << "Publicering: #{publish_enabled? ? 'PÅ' : 'AV (testläge)'}"
  body = lines.join("\n") + "\n"
  puts body
  send_email("📊 نبض السنة – rapport #{today}: #{todays.size} Reels", body) unless DRY
end

case ARGV[0]
when 'slot' then run_slot
when 'report' then report
when 'daily-report'
  # once per day, after the 19:00 slot
  today = Time.now.strftime('%F')
  if Time.now.hour < 19 then log 'Rapporten skickas efter 19:00.'
  elsif read_lines('reels/report.log').include?(today) then log 'Dagens rapport är redan skickad.'
  else
    report
    append_line('reels/report.log', today, "reels: rapport #{today}") unless DRY
  end
else puts File.read(__FILE__)[/^# Reels.*?(?=^require)/m]
end
