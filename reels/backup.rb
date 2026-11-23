#!/usr/bin/env ruby
# Weekly backup of the shared database (publishing history + content bank) to the release "backups".
# Videos are not copied again: they already live in the releases "reels-bank" and "reels-sources"; the backup keeps an index of them.
#   ruby reels/backup.rb            # make a backup now
require 'fileutils'
require 'tmpdir'
require 'time'
require_relative 'common'

gh = Common::GitHub.new(Common.config)
stamp = Time.now.utc.strftime('%Y-%m-%d')
dir = File.join(Dir.tmpdir, "nabd-backup-#{stamp}")
FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)

files = %w[posted.log hadiths.js reels/bank.json reels/published.log reels/errors.log reels/report.log reels/links.txt reels/config.json]
saved = files.map do |f|
  content, = gh.get_file(f)
  next unless content
  dest = File.join(dir, f); FileUtils.mkdir_p(File.dirname(dest)); File.write(dest, content)
  f
end.compact
index = [Common::RELEASE_TAG, Common::SOURCES_TAG].to_h do |tag|
  [tag, gh.assets(tag).map { |a| { 'name' => a['name'], 'size' => a['size'], 'id' => a['id'], 'created_at' => a['created_at'] } }]
end
File.write(File.join(dir, 'video-index.json'), JSON.pretty_generate(index))

tar = File.join(Dir.tmpdir, "backup-#{stamp}.tar.gz")
system('tar', '-czf', tar, '-C', dir, '.', exception: true)
gh.upload_asset(tar, File.basename(tar), Common::BACKUP_TAG, 'application/gzip')
# keep the 26 newest (half a year)
old = gh.assets(Common::BACKUP_TAG).sort_by { |a| a['name'] }.reverse.drop(26)
old.each { |a| gh.api(:delete, "/releases/assets/#{a['id']}") }
puts "Säkerhetskopia #{File.basename(tar)}: #{saved.size} filer + index över #{index.values.sum(&:size)} videor."
