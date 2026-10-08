#!/usr/bin/env ruby
# End-to-end CLI latency, maximum RSS and cancellation using isolated fixtures.
# stdout is drained incrementally; the harness never stores all search results.
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
require_relative 'process_tree_sampler'
repo = File.expand_path('..', __dir__)
binary = ENV.fetch('FINDUI_BINARY', File.join(repo, 'dist/FindUI.app/Contents/MacOS/FindUI'))
worker = ENV.fetch('FINDUI_CONTENT', File.join(File.dirname(binary), 'findui-content'))
rg = File.join(File.dirname(binary), 'rg')
def now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
def measure(env, command, separator, tree_memory: false)
  start = now; first = nil; records = 0; bytes = 0; digest = Digest::SHA256.new
  error = ''; status = nil
  tree = nil
  argv = tree_memory ? command : ['/usr/bin/time', '-l', *command]
  Open3.popen3(env, *argv) do |input, output, diagnostics, wait|
    input.close
    sampler = ProcessTreeSampler.new(wait.pid) if tree_memory
    read_error = Thread.new { diagnostics.read }
    begin
      begin
        loop do
          chunk = output.readpartial(65_536)
          first ||= now - start
          records += chunk.count(separator); bytes += chunk.bytesize; digest.update(chunk)
        end
      rescue EOFError
      end
      status = wait.value; error = read_error.value
    ensure
      tree = sampler.finish if sampler
    end
  end
  raise "#{command.first}: #{error}" unless [0,1].include?(status.exitstatus)
  {firstResultMilliseconds: first && first * 1000, completionMilliseconds: (now - start) * 1000,
   maximumRSSBytes: error[/^\s*(\d+)\s+maximum resident set size/,1]&.to_i,
   records: records, bytes: bytes, sha256: digest.hexdigest, processTree: tree}
end
report = {note: 'Warm disposable fixtures. CLI request to first stdout and completion; not GUI frame latency. Maximum RSS is reported by macOS time. Search output is streamed.',
          cliSHA256: Digest::SHA256.file(binary).hexdigest, workerSHA256: Digest::SHA256.file(worker).hexdigest}
FileUtils.mkdir_p(File.join(repo,'.cache'))
Dir.mktmpdir('responsiveness-',ENV.fetch('FINDUI_BENCHMARK_ROOT',File.join(repo,'.cache'))) do |root|
  files=File.join(root,'files');FileUtils.mkdir_p(files)
  2000.times { |i| File.write(File.join(files,"#{i}.txt"), "needle café\n" * 10) }
  env={'FINDUI_DATA_DIRECTORY'=>File.join(root,'data'),'FINDUI_CACHE_DIRECTORY'=>File.join(root,'cache'),'FINDUI_TIKA_JAR'=>''}
  state={query:'needle',mode:'contents',scopePath:files}
  command=[binary,'--cli','search',JSON.generate(state)]
  native=[rg,'--no-config','--json','--line-number','--ignore-case','--fixed-strings','--','needle',files]
  report[:content]=3.times.map do |i|
    order=i.even? ? [[:findui,command],[:native,native]] : [[:native,native],[:findui,command]]
    result=order.to_h { |name,argv| [name,measure(env,argv,"\n")] }
    # rg includes begin/end/summary records. The CLI strips protocol framing.
    raise 'Lost matching lines' unless result[:findui][:records]==20_000 && result[:native][:records]>20_000
    result
  end
  # Sample memory in separate executions so instrumentation does not inflate
  # the latency comparisons above. Include the CLI and all tool descendants.
  report[:treeMemory] = [[:findui,command],[:native,native]].to_h do |name,argv|
    sample = measure(env, argv, "\n", tree_memory: true)
    expected = name == :findui ? sample[:records] == 20_000 : sample[:records] > 20_000
    raise 'Memory probe lost matching lines' unless expected
    [name, sample.slice(:records, :bytes, :processTree)]
  end
  report[:memoryMethod] = 'Separate 2 ms libproc samples of summed living process RSS. Shared pages may be counted more than once; short-lived processes and peaks between samples can be missed. The sampler is excluded.'
  absent=state.merge(query:'no-such-token-in-this-fixture')
  report[:noHit]=3.times.map { measure(env,[binary,'--cli','search',JSON.generate(absent)],"\n") }
  source=File.join(root,'source.custom');File.write(source,'opaque')
  reader=File.join(root,'slow-reader');started=File.join(root,'started');late=File.join(root,'late')
  File.write(reader, "#!/bin/sh\n/bin/sleep 8 &\nprintf '%s %s' \"$$\" \"$!\" > \"$FINDUI_READY\"\nwait\nprintf late > \"$FINDUI_LATE\"\nprintf 'needle\\n'\n")
  File.chmod(0755,reader)
  plan={leaves:[{pattern:'needle'}],tree:{leaf:0},positive:[0],threads:1,
        extraction:{documents:false,archives:false,maxDepth:5,maxMegabytes:8,timeoutSeconds:20,cacheDirectory:File.join(root,'cache'),
        adapters:[{id:'fixture',title:'Slow reader',extensions:['custom'],executable:reader,arguments:['{path}']}]}}
  log=File.open(File.join(root,'cancel.log'),'w+')
  input_r,input_w=IO.pipe
  pid=Process.spawn(env.merge('FINDUI_READY'=>started,'FINDUI_LATE'=>late),worker,'--plan',JSON.generate(plan),in:input_r,out:log,err:log,pgroup:true)
  input_r.close;input_w.write(source+"\0");input_w.close
  begin
    deadline=now+3
    sleep 0.005 until File.exist?(started) || now>deadline
    raise 'Reader did not start' unless File.exist?(started)
    reader_pids=File.read(started).split.map { |value| Integer(value) }
    raise 'Missing converter process identifiers' unless reader_pids.size == 2
    began=now;Process.kill('TERM',pid);_,status=Process.wait2(pid);elapsed=(now-began)*1000;pid=nil
    alive=lambda { reader_pids.select { |child| begin; Process.kill(0,child); true; rescue Errno::ESRCH; false; end } }
    deadline=now+1
    sleep 0.005 until alive.call.empty? || now>deadline
    raise 'Cancelled converter or grandchild is still running' unless alive.call.empty?
    raise 'Cancelled reader continued work' if File.exist?(late)
    raise 'Cancellation exceeded 2 seconds' if elapsed>2000
    report[:cancellation]={milliseconds:elapsed,exitCode:status.exitstatus,lateSideEffect:false,converterAndGrandchildStopped:true}
  ensure
    if pid
      Process.kill('KILL',-pid) rescue nil
      Process.wait(pid) rescue nil
    end
    log.close
  end
end
puts JSON.pretty_generate(report)
