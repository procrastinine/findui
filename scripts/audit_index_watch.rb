#!/usr/bin/env ruby
require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'

repo = File.expand_path('..', __dir__)
binary = ENV.fetch('FINDUI_BINARY', File.join(repo, '.build/debug/FindUI'))
def await_index(file, seconds: 15)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    if File.exist?(file)
      binary = ENV.fetch('FINDUI_BINARY', File.expand_path('../.build/debug/FindUI', __dir__))
      data, _, status = Open3.capture3(binary, '--cli', 'index', 'export', file)
      value = JSON.parse(data) if status.success?
    end
    return value if value && yield(value)
    raise "Index watcher did not publish expected contents in #{seconds}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.1
  end
end
Dir.mktmpdir('findui-watch-', File.join(repo, '.cache')) do |temporary|
  root = File.realpath(temporary)
  files = File.join(root, 'files'); FileUtils.mkdir_p(files)
  output = File.join(root, 'index.sqlite'); log = File.join(root, 'watch.log')
  File.write(File.join(files, 'before.txt'), 'before')
  config = JSON.generate('scopePath'=>files, 'name'=>'Watch audit', 'includeHidden'=>true)
  pid = nil
  start = -> { pid = Process.spawn(binary, '--cli', 'index', 'watch', config, output, out: log, err: log) }
  stop = -> { Process.kill('TERM', pid) rescue nil; Process.wait(pid) rescue nil; pid = nil }
  begin
    start.call
    await_index(output) { |index| index['entries'].map { |e| e['relativePath'] } == ['before.txt'] }
    File.write(File.join(files, 'new.txt'), 'new')
    await_index(output) { |index| index['entries'].any? { |e| e['relativePath'] == 'new.txt' } }
    File.rename(File.join(files, 'new.txt'), File.join(files, 'renamed.txt'))
    File.unlink(File.join(files, 'before.txt'))
    await_index(output) { |index| index['entries'].map { |e| e['relativePath'] } == ['renamed.txt'] }
    stop.call
    File.write(File.join(files, 'offline.txt'), 'created while watcher was stopped')
    start.call
    await_index(output) { |index| index['entries'].any? { |e| e['relativePath'] == 'offline.txt' } }
    stop.call
    state = JSON.generate('query'=>'offline', 'mode'=>'files', 'scopePath'=>files)
    out, err, status = Open3.capture3(binary, '--cli', 'search', state, '--snapshot', output)
    raise "Headless snapshot query failed: #{err}" unless status.success? && out == File.join(files, 'offline.txt') + "\0"
    puts 'PASS: real FSEvents create/rename/delete, offline replay, atomic snapshots, headless snapshot query'
  rescue => error
    warn File.read(log) if File.exist?(log)
    raise error
  ensure
    stop.call if pid
  end
end
