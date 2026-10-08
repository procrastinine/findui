# Measure the installed worker with fresh synthetic state; no optional tools.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
worker=ENV.fetch('FINDUI_CONTENT',File.expand_path('../dist/FindUI.app/Contents/MacOS/findui-content',__dir__))
Dir.mktmpdir('findui-word-benchmark-') do |root|
  files=File.join(root,'files'); FileUtils.mkdir_p(files)
  paths=2000.times.map { |i| path=File.join(files,"source-#{i}.txt"); File.write(path,'needle original text'); path }
  cache=File.join(root,'cache')
  plan={leaves:[{pattern:'needle'}],tree:{leaf:0},positive:[0],stats:true,indexDirectory:cache,wordRoots:[files],
    extraction:{documents:true,archives:false,cacheDirectory:cache,maxDepth:5,maxMegabytes:16,timeoutSeconds:10}}
  samples=[]
  [['prepare-words',5],['word-candidates',3]].each do |command,rounds|
    rounds.times do |i|
      start=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out,err,status=Open3.capture3(worker,"--#{command}",JSON.generate(plan),stdin_data:command=='prepare-words' ? paths.join("\0")+"\0" : '')
      milliseconds=(Process.clock_gettime(Process::CLOCK_MONOTONIC)-start)*1000
      raise err unless status.success?
      raise 'Candidate membership changed' if command=='word-candidates' && out.lines.length!=paths.length
      samples << {operation:command,round:i,milliseconds:milliseconds,rows:out.lines.size,diagnostics:err}
    end
  end
  puts JSON.pretty_generate({files:paths.length,samples:samples,note:'Preselected path-stream component benchmark; traversal and complete scope coverage are excluded. Partial coverage diagnostics are expected here. First preparation is cold; later updates reuse unchanged sources. Candidate membership is checked each run. verify_app.rb separately checks complete CLI scope coverage.'})
end
