# Render one clip: 1080x1920, blurred-fill background, full original frame, exact Uthmani subtitles, brand, no music.
require 'open3'
require 'fileutils'
require_relative 'analyze'
require_relative 'common'

module Render
  ROOT   = File.expand_path('..', __dir__)
  FFMPEG = Common.tool('ffmpeg', 'FFMPEG', 'bin/ffmpeg')
  MAC_CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  CHROME = ENV['CHROME_BIN'].to_s.empty? ? (File.exist?(MAC_CHROME) ? MAC_CHROME :
           %w[google-chrome google-chrome-stable chromium chromium-browser].map { |n| Common.tool(n, 'X_NONE') }.find { |p| p.include?('/') } || 'google-chrome') : ENV['CHROME_BIN']
  CHROME_EXTRA = RUBY_PLATFORM.include?('linux') ? ['--no-sandbox'] : []
  SUB_H  = 330
  SUB_Y  = 1095
  VID_Y  = 470
  AR_DIGITS = '٠١٢٣٤٥٦٧٨٩'

  def self.ar(n) n.to_s.tr('0123456789', AR_DIGITS) end

  def self.run!(*cmd)
    out, st = Open3.capture2e(*cmd)
    raise "#{File.basename(cmd.first)} failed: #{out[-1500..] || out}" unless st.success?
    out
  end

  # silence intervals in the source audio, cached per source
  def self.silences(work)
    f = File.join(work, 'silence.json')
    return JSON.parse(File.read(f)) if File.exist?(f)
    out = run!(FFMPEG, '-hide_banner', '-nostats', '-i', File.join(work, 'audio.wav'), '-af', 'silencedetect=noise=-32dB:d=0.3', '-f', 'null', '-')
    starts = out.scan(/silence_start: ([\d.]+)/).flatten.map(&:to_f)
    ends   = out.scan(/silence_end: ([\d.]+)/).flatten.map(&:to_f)
    sil = starts.zip(ends).reject { |a, b| b.nil? }
    File.write(f, JSON.generate(sil))
    sil
  end

  # clip in/out points snapped to the pauses around the verses
  def self.bounds(work, c, wd)
    sil = silences(work)
    t0 = c[:run].first[:t0]; t1 = c[:run].last[:t1]
    i0 = c[:run].first[:i0]; i1 = c[:run].last[:i1]
    prev_end   = i0 > 0 ? wd[i0 - 1][2] : 0
    next_start = wd[i1 + 1] ? wd[i1 + 1][1] : t1 + 3
    s_before = sil.select { |a, b| b <= t0 + 0.4 && b >= t0 - 3 }.map(&:last).max
    start = s_before ? s_before - 0.25 : t0 - 0.35
    start = [start, prev_end + 0.05].max
    s_after = sil.select { |a, b| a >= t1 - 0.4 && a <= t1 + 4 }.map(&:first).min
    stop = s_after ? s_after + 0.6 : t1 + 0.8
    stop = [stop, next_start - 0.05].min if next_start > t1
    [[start, 0].max.round(2), stop.round(2)]
  end

  # subtitle chunks with times relative to clip start
  def self.chunks(c, start, stop)
    out = []
    run = c[:run]
    run.each_with_index do |v, vi|
      uw = Quran.uthmani[[v[:s], v[:a]]].split
      sw = v[:k1] - v[:k0] + 1
      n = (uw.size / 6.0).ceil
      per = (uw.size.to_f / n).ceil
      groups = uw.each_slice(per).to_a
      j = 0
      groups.each_with_index do |g, gi|
        # time of this chunk = first matched simple word at/after the proportional position
        sj = (j * sw.to_f / uw.size).floor
        t = nil
        (v[:k0] + sj..v[:k1]).each { |k| if v[:words][k] then t = v[:words][k][0]; break end }
        t ||= v[:t0] + (v[:t1] - v[:t0]) * j / uw.size
        t = v[:t0] if gi.zero?
        out << { text: g.join(' '), num: (gi == groups.size - 1 ? ar(v[:a]) : nil), t: t }
        j += g.size
      end
    end
    out.each_with_index do |x, i|
      x[:a] = [(i.zero? ? start : x[:t]) - start, 0].max.round(2)
      x[:b] = ((out[i + 1] ? out[i + 1][:t] : stop) - start).round(2)
      x.delete(:t)
    end
    out.select { |x| x[:b] > x[:a] }
  end

  def self.clip(src_video, work, c, wd, meta, out_file)
    start, stop = bounds(work, c, wd)
    dur = (stop - start).round(2)
    f = c[:run].first; l = c[:run].last
    rng = f[:a] == l[:a] ? ar(f[:a]) : "#{ar(f[:a])}–#{ar(l[:a])}"
    ch = chunks(c, start, stop)
    spec = { title: "سورة #{Quran.sura_name(f[:s])}", verses: (f[:a] == l[:a] ? "الآية #{rng}" : "الآيات #{rng}"), reciter: meta[:reciter].to_s,
             introKicker: 'تلاوة تخشع لها القلوب', introTitle: "سورة #{Quran.sura_name(f[:s])}",
             subH: SUB_H, chunks: ch.map { |x| { text: x[:text], num: x[:num] } } }
    tmp = File.join(work, "ov-#{File.basename(out_file, '.mp4')}")
    FileUtils.rm_rf(tmp); FileUtils.mkdir_p(tmp)
    FileUtils.cp(File.join(__dir__, 'overlay.html'), tmp)
    File.write(File.join(tmp, 'spec.js'), "window.SPEC = #{JSON.generate(spec)};")
    h = 1920 * 2 + SUB_H * ch.size
    png = File.join(tmp, 'overlay.png')
    run!(CHROME, *CHROME_EXTRA, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=#{tmp}/profile",
         '--allow-file-access-from-files', "--window-size=1080,#{h}", '--force-device-scale-factor=1',
         '--default-background-color=00000000', '--virtual-time-budget=10000', "--screenshot=#{png}",
         "file://#{tmp.gsub(' ', '%20')}/overlay.html")
    raise 'overlay render failed' unless File.size?(png)

    n = ch.size
    fc = []
    fc << "[0:v]setpts=PTS-STARTPTS,fps=30,split=2[v0][v1]"
    fc << "[v0]scale=270:480:force_original_aspect_ratio=increase,crop=270:480,boxblur=12:2,scale=1080:1920,eq=brightness=-0.22:saturation=0.8[bg]"
    fc << "[v1]scale=1080:-2[fg]"
    fc << "[bg][fg]overlay=0:#{VID_Y}[b0]"
    fc << "[1:v]format=rgba,split=#{n + 2}" + (0...(n + 2)).map { |i| "[o#{i}]" }.join
    fc << "[o0]crop=1080:1920:0:0[static]"
    fc << "[o1]crop=1080:1920:0:1920,fade=t=out:st=1.6:d=0.4:alpha=1[intro]"
    ch.each_with_index { |_, i| fc << "[o#{i + 2}]crop=1080:#{SUB_H}:0:#{3840 + i * SUB_H}[s#{i}]" }
    fc << "[b0][static]overlay=0:0[b1]"
    last = 'b1'
    ch.each_with_index do |x, i|
      fc << "[#{last}][s#{i}]overlay=0:#{SUB_Y}:enable='between(t,#{x[:a]},#{x[:b] - 0.01})'[c#{i}]"
      last = "c#{i}"
    end
    fc << "[#{last}][intro]overlay=0:0:enable='lt(t,2.1)',fade=t=in:st=0:d=0.3,fade=t=out:st=#{(dur - 0.5).round(2)}:d=0.5,format=yuv420p[vout]"
    fc << "[0:a]asetpts=PTS-STARTPTS,highpass=f=70,loudnorm=I=-14:TP=-1.5:LRA=11,afade=t=in:d=0.25,afade=t=out:st=#{(dur - 0.6).round(2)}:d=0.6,aresample=48000[aout]"
    run!(FFMPEG, '-y', '-v', 'error', '-ss', start.to_s, '-t', dur.to_s, '-i', src_video,
         '-loop', '1', '-framerate', '30', '-t', dur.to_s, '-i', png,
         '-filter_complex', fc.join(';'), '-map', '[vout]', '-map', '[aout]',
         '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-profile:v', 'high', '-r', '30',
         '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-movflags', '+faststart', '-t', dur.to_s, out_file)
    FileUtils.rm_rf(tmp)
    { start: start, stop: stop, dur: dur, chunks: ch }
  end
end
