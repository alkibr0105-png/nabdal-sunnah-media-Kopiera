#!/usr/bin/env ruby
# Sends a short error email when a workflow fails:  ruby reels/alert.rb "<what failed>"
require 'open3'
require 'tmpdir'
require_relative 'common'

cfg = Common.config
user, pass, to = cfg.values_at('SMTP_USER', 'SMTP_PASS', 'NOTIFY_EMAIL')
exit 0 if [user, pass, to].any? { |v| v.to_s.empty? }
what = ARGV[0].to_s.empty? ? 'Ett automatiskt arbetsflöde' : ARGV[0]
run = ENV['GITHUB_RUN_ID'] ? "https://github.com/#{ENV['GITHUB_REPOSITORY']}/actions/runs/#{ENV['GITHUB_RUN_ID']}" : ''
body = "⚠️ #{what} misslyckades #{Time.now.getlocal('+01:00').strftime('%F %H:%M')}.\n\n" \
       "Systemet försöker igen vid nästa schemalagda körning. Inget publiceras dubbelt.\n\n" \
       "Detaljer (logg): #{run}\n"
msg = <<~MAIL.gsub("\n", "\r\n")
  From: =?UTF-8?B?#{Base64.strict_encode64('نبض السنة – bot')}?= <#{user}>
  To: <#{to}>
  Subject: =?UTF-8?B?#{Base64.strict_encode64("⚠️ Fel: #{what}")}?=
  MIME-Version: 1.0
  Content-Type: text/plain; charset=UTF-8
  Content-Transfer-Encoding: base64

  #{Base64.encode64(body)}
MAIL
f = File.join(Dir.tmpdir, "alert-#{Process.pid}.eml"); File.write(f, msg)
netrc = File.join(Dir.tmpdir, "alert-netrc-#{Process.pid}")
File.write(netrc, "machine smtp.gmail.com login #{user} password #{pass.delete(' ')}\n"); File.chmod(0600, netrc)
out, st = Open3.capture2e('curl', '-sS', '--ssl-reqd', '--url', 'smtps://smtp.gmail.com:465', '--netrc-file', netrc,
                          '--mail-from', user, '--mail-rcpt', to, '--upload-file', f)
File.delete(f, netrc)
puts(st.success? ? 'Felmejl skickat.' : "Felmejl misslyckades: #{out.strip}")
