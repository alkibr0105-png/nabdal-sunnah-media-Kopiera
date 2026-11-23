# Find complete-verse clips (30–90 s) in a transcribed recitation.
require_relative 'quran'

module Analyze
  MIN = 30.0
  MAX = 90.0

  # whisper.cpp JSON (-ml 1 -sow -oj) → [[norm, t0, t1, raw], ...]
  def self.load_words(json_file)
    j = JSON.parse(File.read(json_file, encoding: 'UTF-8'))
    out = []
    j['transcription'].each do |seg|
      t0 = seg.dig('offsets', 'from') / 1000.0
      t1 = seg.dig('offsets', 'to') / 1000.0
      parts = seg['text'].to_s.split
      parts.each_with_index do |p, n|
        w = Quran.norm(p)
        next if w.empty?
        a = t0 + (t1 - t0) * n / parts.size
        b = t0 + (t1 - t0) * (n + 1) / parts.size
        out << [w, a, b, p]
      end
    end
    out
  end

  def self.ayah_first_k
    @first ||= begin
      _, ref = Quran.words; h = {}
      ref.each_with_index { |(s, a, i), k| h[[s, a]] = k if i.zero? }
      h
    end
  end

  # → list of verse timings per passage: [{s:, a:, k0:, k1:, t0:, t1:, cov:, edges:, words: {k => [t0,t1]}}]
  def self.verse_timings(wd, map)
    _, ref = Quran.words
    ks = map.keys.sort
    return [] if ks.empty?
    verses = []
    s, a, = ref[ks.first]
    loop do
      k0 = ayah_first_k[[s, a]]
      break unless k0
      n = Quran.simple[[s, a]].split.size
      k1 = k0 + n - 1
      break if k0 > ks.last
      matched = (k0..k1).select { |k| map[k] }
      if matched.any?
        times = matched.to_h { |k| [k, [wd[map[k]][1], wd[map[k]][2]]] }
        verses << { s: s, a: a, k0: k0, k1: k1, cov: matched.size.to_f / n,
                    first_ok: !map[k0].nil?, last_ok: !map[k1].nil?,
                    t0: times[matched.first][0], t1: times[matched.last][1], words: times,
                    i0: map[matched.first], i1: map[matched.last] }
      end
      a += 1
      if a > Quran.ayas(s) then s += 1; a = 1 end
      break if s > 114
    end
    verses
  end

  def self.good_run?(wd, run)
    return false unless run.first[:first_ok] && run.last[:last_ok]
    return false if run.any? { |v| v[:cov] < 0.6 }
    run.each_cons(2) do |x, y|
      return false unless y[:a] == x[:a] + 1 || (y[:a] == 1 && y[:s] == x[:s] + 1)
      return false if y[:t0] - x[:t1] > 12        # long pause / other speech
      return false if y[:t0] < x[:t1] - 0.5       # out of order
    end
    # unmatched whisper words inside the clip (repetitions, du'a, talk) must be rare
    i0 = run.first[:i0]; i1 = run.last[:i1]
    used = run.sum { |v| v[:words].size }
    used.to_f / (i1 - i0 + 1) >= 0.7
  end

  def self.candidates(wd, passages)
    all = []
    passages.each do |map|
      vs = verse_timings(wd, map)
      vs.each_index do |x|
        (x...vs.size).each do |y|
          run = vs[x..y]
          dur = run.last[:t1] - run.first[:t0]
          break if dur > MAX + 2
          next if dur < MIN
          next unless good_run?(wd, run)
          f = run.first; l = run.last
          score = 0
          score += 3 if Quran.ruku_start?(f[:s], f[:a])
          score += 3 if Quran.ruku_end?(l[:s], l[:a])
          score += 1 if dur.between?(40, 75)
          score += run.sum { |v| v[:cov] } / run.size
          all << { run: run, dur: dur, score: score }
        end
      end
    end
    # best non-overlapping (in time) clips
    picked = []
    all.sort_by { |c| -c[:score] }.each do |c|
      a = c[:run].first[:t0]; b = c[:run].last[:t1]
      next if picked.any? { |p| a < p[:run].last[:t1] + 1 && b > p[:run].first[:t0] - 1 }
      picked << c
    end
    picked.sort_by { |c| c[:run].first[:t0] }
  end
end
