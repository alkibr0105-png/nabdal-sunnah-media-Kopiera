# encoding: utf-8
# نبض السنة — daily Instagram publisher.
#   ruby post.rb --dry-run   → render + print caption, publish nothing
#   ruby post.rb --check     → verify tokens/IDs/repo, publish nothing
#   ruby post.rb             → publish the next unposted, verified hadith
# Rules: only hadiths in hadiths.js (each verified against sunnah.com) are ever posted,
# never the same one twice, at most one post per day. If the bank is empty, nothing is posted.
require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'date'
require 'open3'
require 'tmpdir'

Encoding.default_external = Encoding::UTF_8
DIR    = File.expand_path(__dir__)
LOG    = File.join(DIR, 'posted.log')        # lines: YYYY-MM-DD<TAB>id<TAB>media_id
CONFIG = File.join(DIR, 'config.env')
DRY    = ARGV.include?('--dry-run')

MAC = RUBY_PLATFORM.include?('darwin')

def notify(msg)
  system('osascript', '-e', "display notification #{msg.to_json} with title \"نبض السنة\"") if MAC
  puts msg
end

def die(msg) notify(msg); exit 1 end

def load_config
  # On GitHub Actions there is no config.env: values come from encrypted secrets via environment variables.
  env = %w[GRAPH_HOST GRAPH_VERSION IG_USER_ID IG_ACCESS_TOKEN GITHUB_REPO GITHUB_BRANCH GITHUB_TOKEN]
          .each_with_object({}) { |k, h| h[k] = ENV[k] if ENV[k] && !ENV[k].empty? }
  return env unless File.exist?(CONFIG)
  raw = File.read(CONFIG)
  cfg = raw.lines.each_with_object({}) do |l, h|
    next if l.strip.empty? || l.strip.start_with?('#')
    k, v = l.strip.split('=', 2); h[k] = v.to_s.strip.gsub(/\A["']|["']\z/, '')
  end
  # Tolerant: if a token was pasted anywhere else in the file (e.g. on a comment line), find it there.
  placeholder = ->(v) { v.to_s.empty? || v.start_with?('KLISTRA_IN', 'HAR_SKA') }
  if placeholder.(cfg['IG_ACCESS_TOKEN'])
    t = raw[/\b(EAA[A-Za-z0-9]{50,}|IG[A-Za-z0-9_\-]{50,})/, 1]; cfg['IG_ACCESS_TOKEN'] = t if t
  end
  if placeholder.(cfg['GITHUB_TOKEN'])
    t = raw[/\b(github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,})/, 1]; cfg['GITHUB_TOKEN'] = t if t
  end
  cfg
end

def save_config_value(key, value)
  return unless File.exist?(CONFIG)
  lines = File.readlines(CONFIG).map { |l| l.start_with?("#{key}=") ? "#{key}=#{value}\n" : l }
  lines << "#{key}=#{value}\n" unless lines.any? { |l| l.start_with?("#{key}=") }
  File.write(CONFIG, lines.join)
end

def hadiths
  unless MAC
    js = "global.window = {}; require(#{File.join(DIR, 'hadiths.js').to_json}); process.stdout.write(JSON.stringify(window.HADITHS));"
    out, st = Open3.capture2('node', '-e', js)
    die('تعذّر قراءة hadiths.js') unless st.success?
    return JSON.parse(out)
  end
  js = <<~JS
    ObjC.import('Foundation');
    var s = $.NSString.stringWithContentsOfFileEncodingError(#{File.join(DIR, 'hadiths.js').to_json}, $.NSUTF8StringEncoding, null).js;
    var window = {}; eval(s); JSON.stringify(window.HADITHS);
  JS
  out, st = Open3.capture2('osascript', '-l', 'JavaScript', '-e', js)
  die('تعذّر قراءة hadiths.js') unless st.success?
  JSON.parse(out)
end

def posted
  return [] unless File.exist?(LOG)
  File.readlines(LOG).map { |l| l.split("\t") }
end

def caption(h)
  lines = []
  lines << "#{h['i']}:"
  lines << "«#{h['h']}»"
  lines << "وفي الحديث: «#{h['b']}»" if h['b']
  lines << ''
  lines << "📚 #{h['s']} — الراوي: #{h['n']} — الدرجة: #{h['g']}"
  lines << ''
  lines << '🌿 كيف تعيش هذه السنة اليوم؟'
  h['a'].each { |a| lines << "• #{a}" }
  lines << ''
  lines << 'شارك المنشور، فقد قال ﷺ: «مَنْ دَلَّ عَلَى خَيْرٍ فَلَهُ مِثْلُ أَجْرِ فَاعِلِهِ» (رواه مسلم 1893) 🤍'
  lines << ''
  lines << "🔗 للتحقق من الحديث: #{h['u']}"
  lines << ''
  lines << '#نبض_السنة #حديث_اليوم #السنة_النبوية #حديث #صلى_الله_عليه_وسلم #اتباع_السنة #hadith #sunnah'
  lines.join("\n")
end

def http(method, url, params = nil, headers = {})
  uri = URI(url)
  req = method == :get ? Net::HTTP::Get.new(uri) : (method == :put ? Net::HTTP::Put.new(uri) : Net::HTTP::Post.new(uri))
  headers.each { |k, v| req[k] = v }
  if params.is_a?(String) then req.body = params
  elsif params then req.set_form_data(params) end
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
  body = (JSON.parse(res.body) rescue { 'raw' => res.body })
  [res.code.to_i, body]
end

# Instagram API with Instagram Login (Unified/Business Login) → tokens start with "IG", host graph.instagram.com.
# Instagram API with Facebook Login → tokens start with "EAA", host graph.facebook.com.
def graph_host(cfg)
  return cfg['GRAPH_HOST'] unless cfg['GRAPH_HOST'].to_s.empty?
  cfg['IG_ACCESS_TOKEN'].to_s.start_with?('EAA') ? 'graph.facebook.com' : 'graph.instagram.com'
end

# ---------- e-mail notification (Gmail SMTP via curl; never fails the post) ----------
# Needs env/config: SMTP_USER (Gmail address), SMTP_PASS (Gmail app password), NOTIFY_EMAIL (recipient).
def send_email(subject, body)
  cfg = load_config
  user = ENV['SMTP_USER'] || cfg['SMTP_USER']; pass = ENV['SMTP_PASS'] || cfg['SMTP_PASS']; to = ENV['NOTIFY_EMAIL'] || cfg['NOTIFY_EMAIL']
  if [user, pass, to].any? { |v| v.to_s.empty? } then puts 'E-post: inte konfigurerad, hoppar över.'; return false end
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
  f = File.join(Dir.tmpdir, "nabd-mail-#{Process.pid}.eml"); File.write(f, msg)
  netrc = File.join(Dir.tmpdir, "nabd-netrc-#{Process.pid}")
  File.write(netrc, "machine smtp.gmail.com login #{user} password #{pass.delete(' ')}\n"); File.chmod(0600, netrc)
  out, st = Open3.capture2e('curl', '-sS', '--ssl-reqd', '--url', 'smtps://smtp.gmail.com:465', '--netrc-file', netrc,
                            '--mail-from', user, '--mail-rcpt', to, '--upload-file', f)
  File.delete(f, netrc)
  puts(st.success? ? "E-post skickad." : "E-post misslyckades: #{out.strip}")
  st.success?
end

if ARGV.include?('--test-email')
  ok = send_email('🧪 Test från نبض السنة', "Det här är ett testmejl.\nNär en hadith publiceras får du ett sådant här mejl med länk till inlägget.\n")
  exit(ok ? 0 : 1)
end

# ---------- --check: verify credentials, publish nothing, never print secrets ----------
if ARGV.include?('--check')
  cfg = load_config
  ok = true
  %w[IG_USER_ID IG_ACCESS_TOKEN GITHUB_TOKEN GITHUB_REPO].each do |k|
    v = cfg[k].to_s
    if v.empty? || v.start_with?('KLISTRA_IN', 'HAR_SKA') then puts "✗ #{k} saknas i config.env"; ok = false end
  end
  exit 1 unless ok
  t = cfg['IG_ACCESS_TOKEN']; host = graph_host(cfg); ver = cfg['GRAPH_VERSION'].to_s.empty? ? 'v23.0' : cfg['GRAPH_VERSION']
  puts "Token-typ: #{t.start_with?('EAA') ? 'Facebook Login (EAA…)' : t.start_with?('IG') ? 'Instagram Login (IG…)' : 'okänd'} → #{host}/#{ver}"
  q = URI.encode_www_form_component(t)
  url = host == 'graph.instagram.com' ? "https://#{host}/#{ver}/me?fields=user_id,username&access_token=#{q}"
                                       : "https://#{host}/#{ver}/#{cfg['IG_USER_ID']}?fields=id,username&access_token=#{q}"
  c, r = http(:get, url)
  if c == 200
    ids = [r['user_id'], r['id']].compact.map(&:to_s)
    puts "✓ Instagram-token giltig för @#{r['username']} (id: #{ids.join(' / ')})"
    unless ids.include?(cfg['IG_USER_ID'].to_s)
      puts "✗ IG_USER_ID (#{cfg['IG_USER_ID']}) matchar inte tokenets konto – använd #{r['user_id'] || r['id']}"; ok = false
    end
  else
    puts "✗ Instagram svarade #{c}: #{r.dig('error', 'message')}"; ok = false
  end
  c, r = http(:get, "https://api.github.com/repos/#{cfg['GITHUB_REPO']}",
              nil, 'Authorization' => "Bearer #{cfg['GITHUB_TOKEN']}", 'Accept' => 'application/vnd.github+json')
  if c == 200 && r.dig('permissions', 'push') && !r['private']
    puts "✓ GitHub: #{r['full_name']} är publikt och tokenet har skrivrätt"
  else
    puts "✗ GitHub (#{c}): #{r['message'] || (r['private'] ? 'repot är privat – Instagram kan inte hämta bilden' : 'tokenet saknar skrivrätt')}"; ok = false
  end
  puts(ok ? "\nAllt klart för publicering." : "\nRätta felen ovan innan publicering.")
  exit(ok ? 0 : 1)
end

# ---------- pick ----------
today = Date.today.to_s
log = posted
if !DRY && !ARGV.include?("--force") && log.any? { |r| r[0] == today }
  puts "Already posted today (#{today}). Nothing to do."; exit 0
end
done = log.map { |r| r[1] }
reels_log = File.join(DIR, 'reels.log')
done += File.readlines(reels_log).map { |l| l.split("\t")[1] } if File.exist?(reels_log) # never repeat a hadith already used as a Reel
h = hadiths.find { |x| !done.include?(x['id']) }
die('بنك الأحاديث المُتحقَّق منها انتهى — لن يُنشر شيء حتى تُضاف أحاديث مُتحقَّق منها.') unless h

# ---------- render ----------
img = File.join(DIR, 'out', "#{today}-#{h['id']}.jpg")
_, st = Open3.capture2('bash', File.join(DIR, 'render.sh'), h['id'], img)
die("فشل إنشاء الصورة لـ #{h['id']}") unless st.success? && File.size?(img)
cap = caption(h)

if DRY
  puts "Image: #{img}\n\n#{cap}"; exit 0
end

cfg = load_config
%w[IG_USER_ID IG_ACCESS_TOKEN GITHUB_TOKEN GITHUB_REPO].each do |k|
  v = cfg[k].to_s
  die("الإعداد #{k} ناقص في config.env") if v.empty? || v.start_with?('KLISTRA_IN', 'HAR_SKA')
end
token  = cfg['IG_ACCESS_TOKEN']
graph  = "https://#{graph_host(cfg)}/#{cfg['GRAPH_VERSION'].to_s.empty? ? 'v23.0' : cfg['GRAPH_VERSION']}"
branch = cfg['GITHUB_BRANCH'].to_s.empty? ? 'main' : cfg['GITHUB_BRANCH']

# ---------- host image (public GitHub repo) ----------
path = "posts/#{File.basename(img)}"
gh_auth = { 'Authorization' => "Bearer #{cfg['GITHUB_TOKEN']}", 'Accept' => 'application/vnd.github+json' }
# If the file already exists (e.g. from an earlier failed attempt), GitHub requires its sha to overwrite it.
ecode, existing = http(:get, "https://api.github.com/repos/#{cfg['GITHUB_REPO']}/contents/#{path}?ref=#{branch}", nil, gh_auth)
sha = ecode == 200 && existing.is_a?(Hash) ? existing['sha'] : nil
code, res = http(:put, "https://api.github.com/repos/#{cfg['GITHUB_REPO']}/contents/#{path}",
  JSON.generate({ message: "post #{today} #{h['id']}", content: Base64.strict_encode64(File.binread(img)), branch: branch, sha: sha }.compact),
  gh_auth.merge('Content-Type' => 'application/json'))
die("فشل رفع الصورة إلى GitHub (#{code}): #{res['message']}") unless [200, 201].include?(code)
image_url = "https://raw.githubusercontent.com/#{cfg['GITHUB_REPO']}/#{branch}/#{path}"
sleep 5

# ---------- publish to Instagram ----------
code, res = http(:post, "#{graph}/#{cfg['IG_USER_ID']}/media", image_url: image_url, caption: cap, access_token: token)
die("فشل إنشاء المنشور (#{code}): #{res.dig('error', 'message')}") unless code == 200 && res['id']
container = res['id']
20.times do
  _, s = http(:get, "#{graph}/#{container}?fields=status_code&access_token=#{URI.encode_www_form_component(token)}")
  break if s['status_code'] == 'FINISHED'
  die("رفض Instagram الصورة: #{s['status_code']}") if %w[ERROR EXPIRED].include?(s['status_code'])
  sleep 6
end
code, res = http(:post, "#{graph}/#{cfg['IG_USER_ID']}/media_publish", creation_id: container, access_token: token)
die("فشل النشر (#{code}): #{res.dig('error', 'message')}") unless code == 200 && res['id']

File.open(LOG, 'a') { |f| f.puts [today, h['id'], res['id']].join("\t") }
left = hadiths.size - done.size - 1
notify("تم نشر حديث اليوم: #{h['s']} — المتبقي في البنك: #{left}")

_, pl = http(:get, "#{graph}/#{res['id']}?fields=permalink&access_token=#{URI.encode_www_form_component(token)}")
send_email("✅ Publicerad: #{h['s']}", <<~BODY)
  Dagens hadith är publicerad på @nabdal_sunnah.

  Inlägg: #{pl['permalink'] || '(länk saknas)'}
  Datum: #{today}

  #{h['i']}:
  «#{h['h']}»

  #{h['s']} — #{h['g']}
  Källa: #{h['u']}

  Kvar i banken: #{left} verifierade hadither.#{left <= 5 ? "\n⚠️ Banken håller på att ta slut – lägg till fler verifierade hadither." : ''}
BODY

# Keep an Instagram-Login token alive (long-lived tokens last 60 days; refresh weekly).
if graph.include?('graph.instagram.com') && (cfg['TOKEN_REFRESHED'].to_s.empty? || Date.parse(cfg['TOKEN_REFRESHED']) < Date.today - 7)
  c, r = http(:get, "https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=#{URI.encode_www_form_component(token)}")
  if c == 200 && r['access_token']
    save_config_value('IG_ACCESS_TOKEN', r['access_token']); save_config_value('TOKEN_REFRESHED', today)
  end
end
notify("تنبيه: بقي #{left} أحاديث فقط في البنك. أضف أحاديث مُتحقَّقًا منها.") if left <= 5
