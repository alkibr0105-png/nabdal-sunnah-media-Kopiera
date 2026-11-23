# Quran text + alignment of Whisper word timestamps to exact verses.
# Text source: Tanzil Project (tanzil.net) — used verbatim, never modified.
# Subtitles always come from the Uthmani text; Whisper is only used to find WHICH verses are recited and WHEN.
require 'json'

module Quran
  TOOLS = File.join(__dir__, 'data')   # Tanzil files, kept verbatim with their notices
  DIAC  = /[ؐ-ًؚ-ٰٟۖ-ۭـ࣓-ࣿ]/

  def self.norm(w)
    w.to_s.gsub(DIAC, '').tr('أإآٱ', 'اااا').tr('ى', 'ي').tr('ة', 'ه').tr('ؤ', 'و').tr('ئ', 'ي').gsub(/[^ء-ي]/, '')
  end

  def self.read_text(file)
    h = {}
    File.foreach(File.join(TOOLS, file), encoding: 'UTF-8') do |l|
      s, a, t = l.chomp.split('|', 3)
      next unless t && s =~ /\A\d+\z/
      h[[s.to_i, a.to_i]] = t
    end
    h
  end

  def self.uthmani; @uthmani ||= read_text('quran-uthmani.txt') end
  def self.simple;  @simple  ||= read_text('quran-simple-clean.txt') end

  # QuranData.Sura / QuranData.Ruku from tanzil quran-data.js
  def self.meta
    @meta ||= begin
      js = File.read(File.join(TOOLS, 'quran-data.js'), encoding: 'UTF-8')
      suras = js[/QuranData\.Sura = \[(.*?)\];/m, 1].scan(/\[(\d+), (\d+), (\d+), (\d+), '([^']+)'/).map { |a, n, _o, _r, name| { ayas: n.to_i, name: name } }
      rukus = js[/QuranData\.Ruku = \[(.*?)\];/m, 1].scan(/\[(\d+), (\d+)\]/).map { |s, a| [s.to_i, a.to_i] }
      { suras: [nil] + suras, ruku_starts: rukus.to_h { |x| [x, true] } }
    end
  end

  def self.sura_name(s) meta[:suras][s][:name] end
  def self.ayas(s) meta[:suras][s][:ayas] end
  def self.ruku_start?(s, a) a == 1 || meta[:ruku_starts][[s, a]] end
  def self.ruku_end?(s, a) a == ayas(s) || ruku_start?(s, a + 1) end

  # Flat word list of the whole Quran (simple-clean, normalized)
  def self.words
    @words ||= begin
      w = []; ref = []
      (1..114).each { |s| (1..ayas(s)).each { |a| simple[[s, a]].split.each_with_index { |x, i| w << norm(x); ref << [s, a, i] } } }
      [w, ref]
    end
  end

  def self.index
    @index ||= begin
      w, = words; idx = Hash.new { |h, k| h[k] = [] }
      (0..w.size - 3).each { |k| idx["#{w[k]} #{w[k + 1]} #{w[k + 2]}"] << k }
      idx
    end
  end

  def self.lev(a, b)
    return b.size if a.empty?
    return a.size if b.empty?
    prev = (0..b.size).to_a
    a.each_char.with_index(1) do |ca, i|
      cur = [i]
      b.each_char.with_index(1) { |cb, j| cur << [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1)].min }
      prev = cur
    end
    prev.last
  end

  def self.similar?(a, b)
    return true if a == b
    return false if a.empty? || b.empty?
    m = [a.size, b.size].max
    m >= 3 && lev(a, b).to_f / m <= 0.34
  end

  # wd: [[norm_word, t0, t1], ...]  →  array of passages: { map: {quran_k => whisper_i} }
  def self.align(wd)
    qw, = words
    idx = index
    anchors = []
    (0..wd.size - 3).each do |i|
      c = idx["#{wd[i][0]} #{wd[i + 1][0]} #{wd[i + 2][0]}"]
      next if c.nil? || c.empty? || c.size > 4
      c.each { |k| anchors << [i, k] }
    end
    return [] if anchors.empty?
    # longest chains: increasing i and k, small gaps, steady pace
    n = anchors.size; score = Array.new(n, 1); pred = Array.new(n)
    lo = 0
    n.times do |a|
      ia, ka = anchors[a]
      lo += 1 while anchors[lo][0] < ia - 45
      (lo...a).each do |b|
        ib, kb = anchors[b]
        di = ia - ib; dk = ka - kb
        next unless di > 0 && dk > 0 && dk <= 45 && (dk - di).abs <= 15
        if score[b] + 1 > score[a] then score[a] = score[b] + 1; pred[a] = b end
      end
    end
    used = {}; passages = []
    score.each_index.sort_by { |a| -score[a] }.each do |tail|
      break if score[tail] < 6
      next if used[tail]
      chain = []; a = tail
      while a && !used[a] do chain.unshift(a); a = pred[a] end
      next if chain.size < 6
      chain.each { |x| used[x] = true }
      map = {}
      chain.each { |x| i, k = anchors[x]; 3.times { |j| map[k + j] ||= i + j } }
      # fill gaps between matched words with fuzzy matches
      ks = map.keys.sort
      ks.each_cons(2) do |k1, k2|
        next if k2 - k1 <= 1
        i1 = map[k1]; i2 = map[k2]
        ((k1 + 1)...k2).each do |k|
          ((i1 + 1)...i2).each do |i|
            if similar?(qw[k], wd[i][0]) then map[k] = i; i1 = i; break end
          end
        end
      end
      passages << map
    end
    # drop look-alike passages (similar verses elsewhere) that reuse the same audio as a stronger passage
    taken = {}
    passages.sort_by { |m| -m.size }.select do |m|
      dup = m.values.count { |i| taken[i] }
      next false if dup > m.size * 0.3
      m.each_value { |i| taken[i] = true }
      true
    end
  end
end
