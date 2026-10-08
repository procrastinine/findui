#!/usr/bin/env ruby
# Keep backend builds independent of GUI targets and frameworks.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

root = File.expand_path(ENV.fetch('FINDUI_AUDIT_SOURCE_ROOT', '..'), __dir__)
cache = File.join(root, '.cache/swiftpm')
FileUtils.mkdir_p(cache)
swift_options = ['--package-path', root, '--disable-sandbox', '--disable-keychain',
                 '--disable-netrc', '--cache-path', cache]
capture = lambda do |*args|
  out, err, status = Open3.capture3(*args)
  raise "#{args.first(2).join(' ')} failed: #{err}" unless status.success?
  out
end
package = JSON.parse(capture.call('swift', 'package', *swift_options, 'describe', '--type', 'json'))
product = package.fetch('products').find { |item| item['name'] == 'FindUI' }
raise 'FindUI must build the CLI target' unless product && product['targets'] == ['FindUICLI']
targets = package.fetch('targets').to_h { |target| [target.fetch('name'), target] }

# New dependencies need an explicit review of this boundary. CoreServices is
# used for headless filesystem events and metadata, not windowing.
dependencies = {'SearchCore' => [], 'SearchBackend' => ['SearchCore'], 'FindUICLI' => ['SearchBackend']}
imports = {
  'SearchCore' => %w[Foundation Darwin Glibc],
  # Security stores optional AI credentials in Keychain; CoreFoundation checks
  # JSON Boolean identities without accepting numeric coercions. Neither owns UI.
  'SearchBackend' => %w[Foundation Darwin MachO CryptoKit SQLite3 CoreServices CoreFoundation Security SearchCore],
  'FindUICLI' => %w[Foundation SearchBackend]
}
dependencies.each do |name, expected|
  target = targets.fetch(name)
  unless target.fetch('target_dependencies', []).sort == expected.sort && target.fetch('product_dependencies', []).empty?
    raise "#{name} has dependencies outside the headless boundary"
  end
  target.fetch('sources').each do |source|
    path = File.join(root, target.fetch('path'), source)
    File.foreach(path).with_index(1) do |line, number|
      # Include scoped, attributed and access-controlled Swift imports.
      match = line.match(/^\s*(?:@\w+(?:\([^\n)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/)
      next unless match
      raise "#{path}:#{number}: non-headless import #{match[1]}" unless imports.fetch(name).include?(match[1])
    end
  end
end
puts 'PASS: CLI target graph and backend imports contain only approved headless dependencies'

Dir.mktmpdir('findui-backend-build-') do |scratch|
  build = ['swift', 'build', *swift_options, '--scratch-path', scratch, '--product', 'FindUI', '-c', 'release']
  raise 'Clean headless product build failed' unless system(*build)
  raise 'Headless product compiled the GUI target' unless Dir.glob(File.join(scratch, '**/FindUI.build/*.o')).empty?
  directory = capture.call(*build, '--show-bin-path').strip
  binary = File.join(directory, 'FindUI')
  ui_frameworks = %r{/(?:AppKit|Cocoa|SwiftUI|SwiftUICore|PDFKit|QuickLookUI|UIKit)\.framework/}
  raise 'Headless product links a UI framework' if capture.call('/usr/bin/otool', '-L', binary).match?(ui_frameworks)
  out, trace, status = Open3.capture3({'DYLD_PRINT_LIBRARIES' => '1', 'DYLD_PRINT_TO_FILE' => nil}, binary, '--cli', '--help')
  raise "Headless CLI startup failed: #{trace}" unless status.success? && out.include?('FindUI --cli search')
  raise 'CLI runtime library trace is unavailable' unless trace.match?(%r{^dyld\[\d+\]: .*?/Foundation\.framework/})
  raise 'Headless CLI loads a UI framework' if trace.match?(ui_frameworks)
  puts 'PASS: clean CLI product build and startup without compiling GUI code or loading UI frameworks'
end
