#!/usr/bin/env ruby
# Compare installed FOSS engines on identical candidates and verify membership.
# UGREP is optional; builds/downloads are deliberately outside this benchmark.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

repo = File.expand_path('..', __dir__)
worker = File.join(repo, '.build/content-worker/release/findui-content')
rg = ENV.fetch('RG', 'rg')
ugrep = ENV['UGREP']
rounds = Integer(ENV.fetch('ROUNDS', '5'))
raise 'ROUNDS must be positive' unless rounds.positive?

def run(command, input = '')
  out, err, status = Open3.capture3(*command, stdin_data: input)
  raise "#{command.first}: #{err}" unless [0, 1].include?(status.exitstatus)
  out
end

def measure(cases, rounds)
  expected = nil
  times = cases.to_h { |name, _| [name, []] }
  # Warm each case, then rotate execution order to reduce order/heat bias.
  (0..rounds).each do |iteration|
    cases.to_a.rotate(iteration % cases.length).each do |name, (command, input)|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw = run(command, input)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      paths = raw.split("\0").sort
      expected ||= paths
      raise "Different match sets: #{name}" unless paths == expected
      times[name] << elapsed unless iteration.zero?
    end
  end
  {matches: expected.length, median_seconds: times.transform_values { |v| v.sort[v.length / 2].round(5) }}
end

Dir.mktmpdir('findui-engine-benchmark-', File.join(repo, '.cache')) do |root|
  fixtures = {}
  large = File.join(root, 'large'); FileUtils.mkdir_p(large)
  fixtures[:large_sparse] = 96.times.map do |i|
    path = File.join(large, "large-#{i}.txt")
    File.write(path, "ordinary unrelated text 0123456789\n" * 32_000 + "alpha beta gamma delta\n")
    path
  end
  small = File.join(root, 'small'); FileUtils.mkdir_p(small)
  fixtures[:many_small] = 2_000.times.map do |i|
    folder = File.join(small, "dir-#{i % 40}"); FileUtils.mkdir_p(folder)
    path = File.join(folder, "file-#{i}.txt")
    tail = i % 4 == 0 ? "alpha beta gamma delta\n" : (i % 4 == 1 ? "alpha alone\n" : "no match\n")
    File.write(path, "ordinary text\n" * 32 + tail)
    path
  end
  early = File.join(root, 'early'); FileUtils.mkdir_p(early)
  fixtures[:early_matches] = 24.times.map do |i|
    path = File.join(early, "early-#{i}.txt")
    File.write(path, "alpha beta gamma delta\n" + "ordinary unrelated text 0123456789\n" * 32_000)
    path
  end
  results = {}
  fixtures.each do |label, paths|
    patterns = %w[alpha beta gamma delta]
    plan = {'leaves'=>patterns.map { |p| {'pattern'=>p} }, 'tree'=>{'all'=>4.times.map { |i| {'leaf'=>i} }},
            'positive'=>[0,1,2,3], 'filesOnly'=>true, 'threads'=>4}
    input = paths.join("\0") + "\0"
    compound = {
      findui_ripgrep_four_workers: [[worker, '--plan', JSON.generate(plan)], input],
      rg_pcre2_lookaheads_four_workers: [[rg, '--no-config', '-i', '-l', '--null', '--threads', '4', '-P',
        '--', '^(?=.*alpha)(?=.*beta)(?=.*gamma)(?=.*delta)', *paths], '']
    }
    compound[:ugrep_boolean_four_workers] = [[ugrep, '-i', '-l', '--null', '-J4', '--bool', '-F', '--',
      'alpha beta gamma delta', *paths], ''] if ugrep
    # ugrep's --from is newline-delimited (safe for these generated fixtures).
    # Include its fastest input path so large argv handling cannot decide the result.
    compound[:ugrep_boolean_stdin_four_workers] = [[ugrep, '-i', '-l', '--null', '-J4', '--bool', '-F',
      '--from=-', '--', 'alpha beta gamma delta'], paths.join("\n") + "\n"] if ugrep
    literal = {
      rg_literal_auto: [[rg, '--no-config', '-i', '-l', '--null', '--threads', '0', '-F', '--', 'alpha', *paths], ''],
      rg_literal_four_workers: [[rg, '--no-config', '-i', '-l', '--null', '--threads', '4', '-F', '--', 'alpha', *paths], '']
    }
    literal[:ugrep_literal_auto] = [[ugrep, '-i', '-l', '--null', '-F', '--', 'alpha', *paths], ''] if ugrep
    literal[:ugrep_literal_four_workers] = [[ugrep, '-i', '-l', '--null', '-J4', '-F', '--', 'alpha', *paths], ''] if ugrep
    scope = {large_sparse: large, many_small: small, early_matches: early}.fetch(label)
    literal[:rg_literal_recursive_four_workers] = [[rg, '--no-config', '--hidden', '--no-ignore', '-i', '-l', '--null',
      '--threads', '4', '-F', '--', 'alpha', scope], '']
    literal[:ugrep_literal_recursive_four_workers] = [[ugrep, '--hidden', '-r', '-i', '-l', '--null', '-J4', '-F',
      '--', 'alpha', scope], ''] if ugrep
    results[label] = {files: paths.length, bytes: paths.sum { |p| File.size(p) },
      compound: measure(compound, rounds), literal: measure(literal, rounds)}
  end
  results[:enumeration] = measure({
    fd: [[ENV.fetch('FD', 'fd'), '--hidden', '--no-ignore', '--type', 'f', '--absolute-path', '--print0', '--', '.', small], ''],
    bsd_find: [['/usr/bin/find', small, '-type', 'f', '-print0'], '']
  }, rounds)
  puts JSON.pretty_generate(versions: {rg: run([rg, '--version']).lines.first.strip,
    ugrep: ugrep && run([ugrep, '--version']).lines.first.strip,
    fd: run([ENV.fetch('FD', 'fd'), '--version']).strip}, rounds: rounds, results: results,
    note: 'Synthetic warm-cache fixtures, matching-files output; includes process startup. Explicit lists, ugrep stdin lists, and recursive literal scans cover the same candidates. Every run checks the complete result set. No cold-cache, document, or universal speed claim.')
end
