#!/usr/bin/env ruby
# Validate search lifecycle contracts and collect repeatable timing observations.
# Uses disposable files/caches and the packaged binaries. No optional tools/downloads.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

binary = ENV.fetch('FINDUI_BINARY', File.expand_path('../dist/FindUI.app/Contents/MacOS/FindUI', __dir__))
worker = ENV.fetch('FINDUI_CONTENT', File.join(File.dirname(binary), 'findui-content'))
report = {
  note: 'Warm synthetic fixtures on the local filesystem. Timings include CLI startup; no GUI rendering or cold-I/O claim. Correctness contracts are checked; timings are observations rather than cross-machine performance guarantees.',
  cliSHA256: Digest::SHA256.file(binary).hexdigest,
  workerSHA256: Digest::SHA256.file(worker).hexdigest
}

scratch = ENV.fetch('FINDUI_BENCHMARK_ROOT', File.expand_path('../.cache', __dir__))
FileUtils.mkdir_p(scratch)
Dir.mktmpdir('findui-lifecycle-audit-', scratch) do |temporary|
  root = File.realpath(temporary)
  env = {
    'FINDUI_DATA_DIRECTORY' => File.join(root, 'data'),
    'FINDUI_CACHE_DIRECTORY' => File.join(root, 'cache'),
    'FINDUI_QUERY_CACHE_DIRECTORY' => File.join(root, 'queries'),
    'FINDUI_TIKA_DIRECTORY' => File.join(root, 'tika'),
    'FINDUI_TIKA_JAR' => ''
  }
  run = lambda do |*args|
    output, error, status = Open3.capture3(env, binary, '--cli', *args)
    raise "#{args.first}: #{error}" unless status.success?
    [output, error]
  end

  files = File.join(root, 'snapshot-files')
  FileUtils.mkdir_p(files)
  source = File.join(files, 'needle.txt')
  File.write(source, "needle\n")
  snapshot = File.join(root, 'snapshot.sqlite')
  run.call('index', 'build', JSON.generate(scopePath: files), snapshot)
  state = JSON.generate(query: 'needle', mode: 'files', scopePath: files)
  live, = run.call('search', state, '--explain-plan')
  JSON.parse(live)
  indexed, = run.call('search', state, '--snapshot', snapshot, '--explain-plan')
  plan_json = begin
    JSON.parse(indexed)
    true
  rescue JSON::ParserError
    false
  end
  report[:snapshotExplainPlan] = {
    liveReturnsPlanJSON: true,
    snapshotReturnsPlanJSON: plan_json,
    snapshotActuallyReturnsFilePaths: indexed.split("\0") == [source]
  }

  raise 'Snapshot explain executed the search' unless plan_json && !report[:snapshotExplainPlan][:snapshotActuallyReturnsFilePaths]

  # A deterministic failing reader proves whether unchanged failures are retried.
  failed = File.join(root, 'broken.pdf')
  File.binwrite(failed, "%PDF-1.7\nfixture\n")
  converter = File.join(root, 'failing-pdftotext')
  File.write(converter, <<~'SH')
    #!/bin/sh
    printf 'called\n' >> "$FINDUI_AUDIT_CONVERTER_LOG"
    printf '%s\n' 'Fixture conversion failure' >&2
    exit 7
  SH
  File.chmod(0755, converter)
  count_file = File.join(root, 'converter-calls.txt')
  options = {
    leaves: [{pattern: 'needle'}], tree: {leaf: 0}, positive: [0], threads: 1,
    extraction: {
      documents: true, archives: false, cacheDirectory: File.join(root, 'failed-reader-cache'),
      pdftotext: converter, maxDepth: 5, maxMegabytes: 16, timeoutSeconds: 10
    }
  }
  failures = 2.times.map do
    out, err, status = Open3.capture3(env.merge('FINDUI_AUDIT_CONVERTER_LOG' => count_file),
      worker, '--plan', JSON.generate(options), stdin_data: failed + "\0")
    {exitCode: status.exitstatus, outputRows: out.lines.size, reportsFailure: err.include?('Fixture conversion failure')}
  end
  report[:unchangedConversionFailure] = {
    searches: failures, converterInvocations: File.readlines(count_file).size
  }

  raise 'Unchanged failed conversion ran twice' unless report[:unchangedConversionFailure][:converterInvocations] == 1

  # macOS /var and /private/var refer to the same scope. Creating a previously
  # absent cache must not change coverage identity merely through URL spelling.
  Dir.mktmpdir('findui-word-alias-audit-') do |alias_root|
    alias_root = File.realpath(alias_root)
    scope = File.join(alias_root, 'files'); FileUtils.mkdir_p(scope)
    File.write(File.join(scope, 'source.txt'), "needle text\n")
    alias_env = env.merge('FINDUI_CACHE_DIRECTORY' => File.join(alias_root, 'cache'))
    alias_run = lambda do |*args|
      out, err, status = Open3.capture3(alias_env, binary, '--cli', *args)
      raise err unless status.success?
      out
    end
    state = JSON.generate(query: 'needle', mode: 'contents', scopePath: scope,
      refinements: {wordSearch: true})
    alias_run.call('index', 'words', state)
    first = JSON.parse(alias_run.call('index', 'status', state))
    plan = JSON.parse(alias_run.call('search', state, '--explain-plan'))
    requested = JSON.parse(plan.fetch('stages').first.fetch('invocation').fetch('arguments')[1])
      .fetch('content').fetch('wordScope').fetch('traversal').fetch('excludedPaths')
    db = File.join(alias_root, 'cache', 'words-v1.sqlite')
    saved, err, status = Open3.capture3('/usr/bin/sqlite3', '-json', db, 'SELECT scope FROM word_runs')
    raise err unless status.success?
    saved = JSON.parse(JSON.parse(saved).first.fetch('scope')).fetch('traversal').fetch('excludedPaths')
    alias_run.call('index', 'words', state)
    second = JSON.parse(alias_run.call('index', 'status', state))
    raise 'Coverage identity changed after cache creation' unless first['state'] == 'updated' && second['state'] == 'updated' && saved == requested
    report[:wordIndexScopeAliases] = {
      statusAfterFirstPreparation: first['state'], statusAfterSecondPreparation: second['state'],
      savedAndRequestedExclusionsDiffer: saved != requested,
      savedCachePath: saved.first, requestedCachePath: requested.first
    }
  end

  report[:preparedWordNoHitSearch] = [1_000, 10_000].map do |count|
    scope = File.join(root, "words-#{count}")
    FileUtils.mkdir_p(scope)
    count.times { |i| File.write(File.join(scope, "source-#{i}.txt"), "ordinary searchable text\n") }
    state = {query: 'absentauditterm', mode: 'contents', scopePath: scope,
      refinements: {wordSearch: true}}
    run.call('index', 'words', JSON.generate(state))
    status = JSON.parse(run.call('index', 'status', JSON.generate(state)).first)
    raise "Word coverage is incomplete: #{status.inspect}" unless status['state'] == 'updated' && status['sources'] == count
    samples = 7.times.map do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, = run.call('search', JSON.generate(state))
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1_000
      raise 'Expected no results' unless out.empty?
      elapsed
    end
    verified = JSON.parse(run.call('index', 'status', JSON.generate(state)).first)
    {sources: count, milliseconds: samples, status: status['state'], verification: verified['verification']}
  end
end

puts JSON.pretty_generate(report)
