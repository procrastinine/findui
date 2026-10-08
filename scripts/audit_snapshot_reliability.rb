#!/usr/bin/env ruby
# Stress the distributable's cold snapshot publication with independent builds
# and simultaneous readers. A failure retains its app, index, cache and outputs.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'thread'
app=File.expand_path(ARGV[0] || File.join(__dir__,'../dist/FindUI.app'))
iterations=Integer(ARGV[1] || 40); parallel=Integer(ARGV[2] || 4)
raise 'Use positive iteration and concurrency counts' unless iterations>0 && (1..16).cover?(parallel)
root=Dir.mktmpdir('findui-snapshot-reliability-'); complete=false
begin
  copy=File.join(root,'FindUI.app');FileUtils.cp_r(app,copy)
  File.unlink(File.join(copy,'Contents/MacOS/FindUIApp'))
  binary=File.join(copy,'Contents/MacOS/FindUI')
  queue=Queue.new; iterations.times { |i|queue << i }; mutex=Mutex.new; failures=[]
  Array.new(parallel) do
    Thread.new do
      loop do
        begin; i=queue.pop(true); rescue ThreadError; break; end
        fixture=File.join(root,"fixture-#{i}");files=File.join(fixture,'files');FileUtils.mkdir_p(files)
        File.write(File.join(files,'needle.txt'),"needle original\n")
        File.write(File.join(files,'second.md'),"needle nearby\n")
        env={'PATH'=>'/usr/bin:/bin:/usr/sbin:/sbin','DYLD_PRINT_LIBRARIES'=>'1','DYLD_PRINT_TO_FILE'=>nil,
             'FINDUI_CACHE_DIRECTORY'=>File.join(fixture,'cache'),'FINDUI_DATA_DIRECTORY'=>File.join(fixture,'data'),
             'FINDUI_QUERY_CACHE_DIRECTORY'=>File.join(fixture,'query-cache'),'FINDUI_READER_CONFIG'=>File.join(fixture,'readers.json'),
             'FINDUI_TIKA_DIRECTORY'=>File.join(fixture,'tika'),'FINDUI_TIKA_JAR'=>''}
        command_lock=Mutex.new
        run=lambda do |*args|
          out,err,status=Open3.capture3(env,binary,'--cli',*args)
          command_lock.synchronize { File.open(File.join(fixture,'commands.jsonl'),'a') { |log|log.puts(JSON.generate(arguments:args,stdout:out,stderr:err,exit:status.exitstatus)) } }
          raise "#{args.first}: #{err}" unless status.success?
          out
        end
        begin
          state={'query'=>'needle','mode'=>'contents','scopePath'=>files}
          run.call('search',state.to_json);run.call('index','words',state.to_json)
          state['refinements']={'wordSearch'=>true}
          run.call('search',state.to_json);run.call('index','status',state.to_json)
          run.call('suggest',state.to_json,'ne');run.call('facets','search',state.to_json)
          snapshot=File.join(fixture,'names.sqlite')
          run.call('index','build',{'scopePath'=>files,'name'=>'Installation check'}.to_json,snapshot)
          query={'query'=>'needle','mode'=>'files','scopePath'=>files,'useIndex'=>true}.to_json
          check=lambda do
            actual=run.call('search',query,'--snapshot',snapshot).split("\0")
            expected=[File.join(files,'needle.txt')]
            raise "Expected #{expected.inspect}; got #{actual.inspect}" unless actual==expected
          end
          # All three readers contend for publication of the same cold cache.
          readers=Array.new(3) { Thread.new { begin; check.call; nil; rescue => error; error; end } }
          errors=readers.map(&:value).compact
          raise errors.first unless errors.empty?
          File.unlink(File.join(files,'needle.txt'))
          check.call # Cached reads must retain frozen membership after deletion.
          FileUtils.remove_entry(fixture)
        rescue => error
          mutex.synchronize { failures << {iteration:i,error:error.message};warn "FAIL: snapshot #{i}: #{error.message}" }
        end
      end
    end
  end.each(&:join)
  File.write(File.join(root,'report.json'),JSON.pretty_generate(iterations:iterations,queries:iterations*4,concurrency:parallel,failures:failures))
  raise "Snapshot failures retained at #{root}" unless failures.empty?
  puts "PASS: #{iterations} isolated builds, #{iterations*4} snapshot queries, #{parallel} concurrent builds, three simultaneous cold readers and frozen reads after deletion"
  complete=true
ensure
  FileUtils.remove_entry(root) if complete
end
