#!/usr/bin/env ruby
# Compare both correctness-preserving freshness routes on the same large scope.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

repo = File.expand_path('..', __dir__)
worker = ENV.fetch('FINDUI_CONTENT', File.join(repo, 'dist/FindUI.app/Contents/MacOS/findui-content'))
count = Integer(ENV.fetch('FINDUI_FRESHNESS_FILES', '100000'))
raise 'Use 1–200000 files' unless (1..200_000).cover?(count)
report = {note: 'Warm synthetic metadata verification, including worker startup. Automatic mode only replays events when a previous complete metadata scan cost at least 250 ms. No source contents are read by status.', sources: count}
report[:workerSHA256] = Digest::SHA256.file(worker).hexdigest
baseline = ENV['FINDUI_FRESHNESS_BASELINE']
report[:baselineSHA256] = Digest::SHA256.file(baseline).hexdigest if baseline
FileUtils.mkdir_p(File.join(repo, '.cache'))
Dir.mktmpdir('word-freshness-', ENV.fetch('FINDUI_BENCHMARK_ROOT', File.join(repo, '.cache'))) do |root|
  files = File.join(root, 'files'); FileUtils.mkdir_p(files)
  count.times do |i|
    directory = File.join(files, (i / 1000).to_s)
    FileUtils.mkdir_p(directory) if i % 1000 == 0
    File.write(File.join(directory, "#{i}.txt"), "ordinary searchable text\n")
  end
  content = {tree: {leaf: 0}, leaves: [{pattern: 'absent'}], positive: [0], threads: 4,
    indexDirectory: File.join(root, 'cache'), wordRoots: [files],
    wordScope: {unfiltered: true, traversal: {follow: false}}}
  plan = {version: 1, source: {kind: 'live'}, action: 'prepareWords', unit: 'line', output: 'matches',
    traversal: {roots: [files], hidden: true, ignored: false, ignorePolicy: 'ripgrep', follow: false, minimumDepth: 1, packages: true, kind: 'f'},
    budget: {workers: 4, conversionWorkers: 4, memoryBytes: 67_108_864}, content: content}
  # Reader identity includes the worker executable. Each build must prepare
  # its own cache; sharing a cache would correctly report a changed reader.
  variants = {'current' => worker}; variants['baseline'] = baseline if baseline
  configurations = variants.to_h do |name, executable|
    requested = content.merge(indexDirectory: File.join(root, "cache-#{name}"))
    _, error, status = Open3.capture3(executable, '--execute', JSON.generate(plan.merge(content: requested)))
    raise error unless status.success?
    [name, requested]
  end
  content = configurations.fetch('current')
  check = lambda do |mode, requested = content, executable = worker|
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, error, status = Open3.capture3({'FINDUI_WORD_FRESHNESS' => mode}, executable, '--word-status', JSON.generate(requested))
    raise error unless status.success?
    value = JSON.parse(out)
    value.merge('elapsedMilliseconds' => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000)
  end
  first = check.call('metadata'); raise first.inspect unless first['state'] == 'updated' && first['sources'] == count
  report[:samples] = 5.times.map do |round|
    modes = %w[auto metadata events].rotate(round % 3)
    modes.to_h do |mode|
      value = check.call(mode)
      raise value.inspect unless value['state'] == 'updated' && value['sources'] == count
      [mode, value.slice('elapsedMilliseconds', 'verification', 'verificationMilliseconds')]
    end
  end
  report[:fullScopeComparison] = 5.times.map do |round|
    variants.to_a.rotate(round % variants.size).to_h do |name, executable|
      value = check.call('metadata', configurations.fetch(name), executable)
      raise value.inspect unless value['state'] == 'updated' && value['sources'] == count
      [name, value.slice('elapsedMilliseconds', 'verificationMilliseconds', 'sources')]
    end
  end
  report[:narrowScope] = {sources: [count, 1000].min, samples: 7.times.map do |round|
    variants.to_a.rotate(round % variants.size).to_h do |name, executable|
      scoped = configurations.fetch(name).merge(wordRoots: [File.join(files, '0')])
      value = check.call('metadata', scoped, executable)
      raise value.inspect unless value['state'] == 'updated' && value['sources'] == [count, 1000].min
      [name, value.slice('elapsedMilliseconds', 'verificationMilliseconds', 'sources')]
    end
  end}
  File.write(File.join(files, '0/0.txt'), "changed contents\n")
  report[:changedFileDetected] = %w[auto metadata events].to_h { |mode| [mode, check.call(mode)['state'] == 'needsUpdate'] }
  raise 'Freshness proof missed a changed file' unless report[:changedFileDetected].values.all?
end
puts JSON.pretty_generate(report)
