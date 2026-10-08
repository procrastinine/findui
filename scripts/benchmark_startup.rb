#!/usr/bin/env ruby
# Warm filesystem, fresh processes; run without concurrent builds or benchmarks.
require 'json'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require 'digest'

APP = ENV.fetch('FINDUI_BINARY', File.expand_path('../dist/FindUI.app/Contents/MacOS/FindUI', __dir__))
ROUNDS = Integer(ENV.fetch('ROUNDS', '31'))
REPORT = ENV.fetch('REPORT', File.expand_path('../.cache/startup-audit/latest.json', __dir__))
raise 'ROUNDS must be positive' unless ROUNDS.positive?

def capture(argv)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, err, status = Open3.capture3(*argv)
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  diagnostics = err.lines.reject { |line| line.strip.empty? || line.start_with?('findui-completion: ', 'findui-stats: ') }
  raise "#{argv.first}: #{status.exitstatus}: #{err}" unless [0, 1].include?(status.exitstatus) && diagnostics.empty?
  [out, elapsed]
end

def median(values)
  values.sort[values.size / 2].round(4)
end

def validate(output, kind, expected)
  actual = case kind
           when :text then output.lines.map { |line| JSON.parse(line) }.filter_map do |record|
             next unless record['type'] == 'match'
             data = record.fetch('data')
             [File.realpath(data.fetch('path').fetch('text')), data.fetch('line_number'), data.fetch('lines').fetch('text'),
              data.fetch('submatches').map { |m| [m.fetch('start'), m.fetch('end')] }]
           end
           when :paths then output.split("\0").map { |path| File.realpath(path) }
           when :command then Shellwords.split(output).drop(1)
           else return
           end
  raise "Unexpected #{kind} results: #{actual.inspect}" unless actual == expected
end

apps = { 'current' => APP }
apps['baseline'] = ENV['BASELINE_APP'] if ENV['BASELINE_APP']
report = { rounds: ROUNDS, description: 'One warmup, rotated fresh-process runs on one matching file. Includes launcher and pipe costs. Every result is verified outside timing; no cold filesystem or GUI rendering measurements.',
           binaries: apps.transform_values { |file| Digest::SHA256.file(file).hexdigest } }
Dir.mktmpdir('findui-startup-', ENV.fetch('FINDUI_BENCHMARK_ROOT', '/private/tmp')) do |root|
  root = File.realpath(root)
  file = File.join(root, 'needle.txt')
  File.write(file, "needle text\n")
  names = { mode: 'files', query: 'needle', scopePath: root, refinements: { workers: 4 } }
  contents = names.merge(mode: 'contents')
  inputs = { 'names' => [names, :paths, [file]],
             'contents' => [contents, :text, [[file, 1, "needle text\n", [[0, 6]]]]],
             'compound' => [contents.merge(refinements: { workers: 4, fileQuery: 'needle' }), :text, [[file, 1, "needle text\n", [[0, 6]]]]],
             'absent' => [contents.merge(query: 'absent'), :text, []],
             'files_only' => [contents.merge(refinements: { workers: 4, matchingFilesOnly: true }), :paths, [file]] }
  cases = { 'process_baseline' => [['/usr/bin/true'], nil, nil] }
  apps.each do |label, app|
    cases[label + '/help'] = [[app, '--cli', '--help'], nil, nil]
    inputs.each do |name, (state, kind, expected)|
      args = [app, '--cli', 'search', state.to_json]
      command, = capture(args + ['--print-command'])
      argv = Shellwords.split(command)
      cases["#{label}/#{name}/plan"] = [args + ['--print-command'], :command, argv.drop(1)]
      cases["#{label}/#{name}/native"] = [argv, kind, expected]
      cases["#{label}/#{name}/cli"] = [args, kind, expected]
    end
  end
  samples = cases.to_h { |label, _| [label, []] }
  (0..ROUNDS).each do |iteration|
    cases.to_a.rotate(iteration % cases.size).each do |label, (argv, kind, expected)|
      out, ms = capture(argv)
      validate(out, kind, expected)
      samples[label] << ms unless iteration.zero?
    end
  end
  report[:milliseconds] = samples.transform_values { |values| median(values) }
  report[:samples] = samples.transform_values { |values| values.map { |v| v.round(4) } }

  if (profile = ENV['FINDUI_STARTUP_PROFILE'])
    report[:preparation_milliseconds] = { 'names' => names, 'contents' => contents }.transform_values do |state|
      values = 11.times.map { JSON.parse(capture([profile, state.to_json]).first) }
      { first: values.map(&:first), warm: values.flat_map { |v| v.drop(1) } }.transform_values do |rows|
        rows.first.keys.to_h { |key| [key, median(rows.map { |row| row.fetch(key) })] }
      end
    end
  end
end
FileUtils.mkdir_p(File.dirname(REPORT))
File.write(REPORT, JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report.reject { |key, _| key == :samples })
puts REPORT
