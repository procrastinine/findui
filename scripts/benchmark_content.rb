#!/usr/bin/env ruby
# Compares a single-pass compound search against four separate rg scans BEFORE
# their merge cost. Synthetic fixture, warm filesystem cache, three repetitions.
require 'json'
require 'open3'
require 'tmpdir'

repo = File.expand_path('..', __dir__)
worker = File.join(repo, '.build/content-worker/release/findui-content')
rg = ENV.fetch('RG', 'rg')
Dir.mktmpdir('findui-benchmark-', File.join(repo, '.cache')) do |root|
  noise = ("ordinary unrelated text 0123456789\n" * 32000)
  paths = 96.times.map do |i|
    path = File.join(root, "file-#{i}.txt")
    File.write(path, noise + "alpha beta gamma delta\n")
    path
  end
  patterns = %w[alpha beta gamma delta]
  reference = nil
  measurements = {}
  [[:four_rg_scans, nil], [:single_pass_one_worker, 1], [:single_pass_four_workers, 4]].each do |label, threads|
    times = 3.times.map do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if threads
        plan = {'leaves'=>patterns.map { |p| {'pattern'=>p} }, 'tree'=>{'all'=>4.times.map { |i| {'leaf'=>i} }},
                'positive'=>[0,1,2,3], 'threads'=>threads}
        raw, error, status = Open3.capture3(worker, '--plan', JSON.generate(plan), stdin_data: paths.join("\0") + "\0")
        raise error unless status.success?
        outputs = [raw]
      else
        outputs = patterns.map do |pattern|
          raw, error, status = Open3.capture3(rg, '--no-config', '--json', '--threads', '1', '--fixed-strings', '--ignore-case', '--', pattern, *paths)
          raise error unless status.success?
          raw
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      matches = outputs.map { |raw| raw.lines.filter_map { |line| row = JSON.parse(line); [row['data']['path']['text'],row['data']['line_number']] if row['type']=='match' }.sort }
      reference ||= matches.first
      raise 'Different match sets' unless matches.all? { |m| m == reference }
      elapsed
    end
    measurements[label] = times.sort[1].round(4)
  end
  puts JSON.pretty_generate(files:paths.length, bytes:paths.sum { |p| File.size(p) }, matches:reference.length,
    conditions:patterns.length, median_seconds:measurements,
    note:'Synthetic warm-cache fixture; four rg scans exclude their later merge cost. Performance varies by workload.')
end
