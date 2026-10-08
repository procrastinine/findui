require 'json'
require 'fileutils'
metadata, destination = ARGV
FileUtils.mkdir_p(destination)
packages = JSON.parse(File.read(metadata)).fetch('packages')
notices = packages.map do |package|
  next if package['name'] == 'findui-content'
  label = "#{package['name']}-#{package['version']}"
  folder = File.join(destination, label); FileUtils.mkdir_p(folder)
  root = File.dirname(package.fetch('manifest_path'))
  files = %w[LICENSE* COPYING* UNLICENSE NOTICE*].flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
  files << File.join(root, package['license_file']) if package['license_file']
  files.uniq.select { |path| File.file?(path) }.each { |path| FileUtils.cp(path, folder) }
  "#{label}: #{package['license']}\n#{package['repository']}"
end.compact
notices << "libarchive: system library supplied by macOS; not redistributed in FindUI\nUpstream BSD licensing: https://github.com/libarchive/libarchive/blob/master/COPYING"
File.write(File.join(destination, 'THIRD_PARTY_NOTICES.txt'), notices.join("\n\n") + "\n")
