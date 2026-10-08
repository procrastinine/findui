#!/usr/bin/env ruby
# Full-process comparisons, with independently generated expected records.
# No builds, unrelated benchmarks or tests should run during measurement.
require 'json'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require 'digest'
APP=ENV.fetch('FINDUI_BINARY',File.expand_path('../dist/FindUI.app/Contents/MacOS/FindUI',__dir__))
BIN=File.dirname(APP)
FD=ENV.fetch('FD',File.join(BIN,'fd')); RG=ENV.fetch('RG',File.join(BIN,'rg'))
ROUNDS=Integer(ENV.fetch('ROUNDS','5'))
REPORT=ENV.fetch('REPORT',File.expand_path('../.cache/backend-redesign/planner-benchmark.json',__dir__))

def execute(argv)
  start=Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out,err,status=Open3.capture3(*argv)
  ms=(Process.clock_gettime(Process::CLOCK_MONOTONIC)-start)*1000
  raise "#{argv.first}: #{status.exitstatus}: #{err}" unless [0,1].include?(status.exitstatus)
  diagnostics=err.lines.reject { |l| l.start_with?('findui-completion: ','findui-stats: ') || l.strip.empty? }
  raise diagnostics.join unless diagnostics.empty?
  [out,ms]
end

def records(raw,root,json)
  return raw.split("\0").map { |p|File.realpath(p).delete_prefix(root+'/') }.sort unless json
  raw.lines.map { |l|JSON.parse(l) }.filter_map do |r|
    next unless r['type']=='match'
    d=r.fetch('data')
    [File.realpath(d.fetch('path').fetch('text')).delete_prefix(root+'/'),d['line_number'],d.fetch('lines').fetch('text'),d.fetch('submatches').map { |m|[m.fetch('start'),m.fetch('end')] }]
  end.sort
end

def measure(label,root,state,expected,alternatives,json:true)
  payload=state.merge('scopePath'=>root,'includeHidden'=>true).to_json
  command,_=execute([APP,'--cli','search',payload,'--print-command'])
  plan_json,_=execute([APP,'--cli','search',payload,'--explain-plan'])
  plan=JSON.parse(plan_json)
  candidates={'planned_export'=>Shellwords.split(command),'full_cli'=>[APP,'--cli','search',payload]}.merge(alternatives)
  timings=candidates.to_h { |name,_|[name,[]] }
  (0..ROUNDS).each do |iteration|
    candidates.to_a.rotate(iteration%candidates.size).each do |name,argv|
      raw,ms=execute(argv)
      actual=records(raw,root,json)
      raise "#{label}/#{name}: #{actual.length} results differ from #{expected.length} expected" unless actual==expected
      timings[name] << ms unless iteration==0
    end
  end
  medians=timings.transform_values { |x|x.sort[x.size/2].round(3) }
  puts "#{label}: #{medians.inspect}, #{expected.size} verified records";STDOUT.flush
  {results:expected.size,stages:plan.fetch('stages').map { |s|s['label'] },
   reasons:plan['reasons'],commands:candidates,milliseconds:medians,samples:timings.transform_values { |xs|xs.map { |v|v.round(3) } }}
end

def rg(root,pattern,paths:false,pcre:false)
  [RG,'--no-config',*(paths ? ['--files-with-matches','--null'] : ['--json','--line-number']),
   '--hidden','--ignore-case',*(pcre ? ['--pcre2'] : ['--fixed-strings']),'--threads','4','--',pattern,root]
end

def fd(root,pattern='')
  [FD,'--absolute-path','--print0','--type','f','--hidden','--ignore-case','--threads','4','--fixed-strings','--full-path','--',pattern,root]
end

def pipeline(source,pattern,paths:false)
  scan=[RG,'--no-config',*(paths ? ['--files-with-matches','--null'] : ['--json','--line-number']), '--ignore-case','--fixed-strings','--threads','4','--',pattern]
  # -n bounds argv; explicit file arguments avoid a second traversal.
  ['/bin/bash','--noprofile','--norc','-c',source.shelljoin+' | /usr/bin/xargs -0 -n 1024 '+scan.shelljoin]
end

report={}
Dir.mktmpdir('findui-planner-benchmark-',ENV.fetch('FINDUI_BENCHMARK_ROOT','/private/tmp')) do |tmp|
 root=File.realpath(tmp); small=File.join(root,'small');FileUtils.mkdir_p(small)
 names=[];small_rows=[]
 2000.times do |i|
   relative="d#{i%40}/#{i%4==0 ? 'needle' : 'file'}-#{i}.txt";path=File.join(small,relative)
   FileUtils.mkdir_p(File.dirname(path));hit=i%4==0
   File.write(path,"ordinary text\n"*32+(hit ? "needle text\n" : "unrelated\n"))
   if hit;names << relative;small_rows << [relative,33,"needle text\n",[[0,6]]];end
 end
 state={'mode'=>'contents','query'=>'needle','refinements'=>{'workers'=>4}}
 report['names_2000']=measure('names_2000',small,state.merge('mode'=>'files'),names.sort,{'direct_fd'=>fd(small,'needle')},json:false)
 report['literal_2000']=measure('literal_2000',small,state,small_rows.sort,{'direct_rg'=>rg(small,'needle')})
 report['absent_2000']=measure('absent_2000',small,state.merge('query'=>'impossible'),[],{'direct_rg'=>rg(small,'impossible')})
 filtered=Marshal.load(Marshal.dump(state));filtered['refinements']['fileQuery']='needle'
 report['path_and_content_2000']=measure('path_and_content_2000',small,filtered,small_rows.sort,{'fd_to_rg'=>pipeline(fd(small,'needle'),'needle')})
 typed=Marshal.load(Marshal.dump(state));typed['refinements']['extensions']='txt'
 report['extension_and_content_2000']=measure('extension_and_content_2000',small,typed,small_rows.sort,{'direct_rg_type'=>[RG,'--type-add','bench:*.[tT][xX][tT]','--type','bench',*rg(small,'needle').drop(1)],'fd_to_rg'=>pipeline([FD,'--hidden','--absolute-path','--print0','--type','f','--threads','4','--extension','txt','--','',small],'needle')})
 large=File.join(root,'large');FileUtils.mkdir_p(large)
 rows=48.times.map do |i|
   name="needle-#{i}.txt";File.write(File.join(large,name),"ordinary unrelated text 0123456789\n"*32_000+"needle text\n")
   [name,32_001,"needle text\n",[[0,6]]]
 end.sort
 report['literal_48_large']=measure('literal_48_large',large,state,rows,{'direct_rg'=>rg(large,'needle')})
 report['path_and_content_48_large']=measure('path_and_content_48_large',large,filtered,rows,{'fd_to_rg'=>pipeline(fd(large,'needle'),'needle')})
 dense=File.join(root,'dense');FileUtils.mkdir_p(dense);rows=[]
 4.times do |i|
   name="needle-#{i}.txt";File.write(File.join(dense,name),"needle text\n"*25_000)
   25_000.times { |j|rows << [name,j+1,"needle text\n",[[0,6]]] }
 end
 report['literal_100000_lines']=measure('literal_100000_lines',dense,state,rows.sort,{'direct_rg'=>rg(dense,'needle')})
 report['path_and_content_100000_lines']=measure('path_and_content_100000_lines',dense,filtered,rows.sort,{'fd_to_rg'=>pipeline(fd(dense,'needle'),'needle')})
 # Same-line AND/NOT membership. PCRE2 lookaheads are a straightforward exact
 # baseline for these generated lines; files-only avoids highlight differences.
 boolean=File.join(root,'boolean');FileUtils.mkdir_p(boolean);expected=[]
 800.times do |i|
   text=i%4==0 ? "alpha beta\n" : i%4==1 ? "alpha beta banned\n" : i%4==2 ? "alpha\nbeta\n" : "other\n"
   name="file-#{i}.txt";File.write(File.join(boolean,name),text*100);expected << name if i%4==0
 end
 composed=state.merge('query'=>'alpha beta -banned','refinements'=>{'workers'=>4,'matchingFilesOnly'=>true})
 report['boolean_lines_800']=measure('boolean_lines_800',boolean,composed,expected.sort,{'direct_rg_pcre'=>rg(boolean,'^(?=.*alpha)(?=.*beta)(?!.*banned)',paths:true,pcre:true)},json:false)
 # Cross-domain OR with overlapping filename branches. The independent baseline
 # runs each eligible rg scan and deduplicates its NUL paths. Files in both
 # branches may be read twice there; the mixed executor shares the content scan.
 mixed=File.join(root,'mixed');FileUtils.mkdir_p(mixed);expected=[]
 1200.times do |i|
   stem=%w[src-test src test][i%3];name="#{stem}-#{i}.txt"
   ending=['alpha','beta','alpha beta','ordinary','ordinary'][i%5]
   File.write(File.join(mixed,name),"ordinary unrelated text 0123456789\n"*1024+ending+"\n")
   expected << name if (stem.include?('src') && ending.include?('alpha')) || (stem.include?('test') && ending.include?('beta'))
 end
 leaf=->(domain,predicate){{'rule'=>{'_0'=>{domain=>{'_0'=>predicate}}}}}
 branch=->(name,word){{'all'=>{'_0'=>[leaf.call('file',{'name'=>{'_0'=>name,'_1'=>'contains'}}),leaf.call('content',{'literal'=>{'_0'=>word}})]}}}
 mixed_state={'mode'=>'contents','criteria'=>{'grouped'=>{'_0'=>{
   'expression'=>{'any'=>{'_0'=>[branch.call('src','alpha'),branch.call('test','beta')]}},'contentUnit'=>'file'},
   'options'=>{'additionalScopes'=>[],'source'=>'filesystem','fileCaseSensitive'=>false,'wholeWords'=>false,
     'matchingFilesOnly'=>true,'contextLines'=>0,'fuzzyFullPath'=>false,'workers'=>4}}}}
 branches=[['src','alpha'],['test','beta']].map { |name,word|
   [RG,'--no-config','--files-with-matches','--null','--hidden','--ignore-case','--fixed-strings',
    '--threads','4','--glob',"*#{name}*",'--',word,mixed].shelljoin }
 union="( #{branches.join('; ')} ) | #{['/usr/bin/perl','-0ne','print unless $seen{$_}++'].shelljoin}"
 report['mixed_overlapping_branches_1200']=measure('mixed_overlapping_branches_1200',mixed,mixed_state,expected.sort,
   {'two_rg_scans'=>['/bin/bash','--noprofile','--norc','-e','-o','pipefail','-c',union]},json:false)
end
FileUtils.mkdir_p(File.dirname(REPORT))
File.write(REPORT,JSON.pretty_generate({rounds:ROUNDS,appSHA256:Digest::SHA256.file(APP).hexdigest,
 workerSHA256:Digest::SHA256.file(File.join(BIN,'findui-content')).hexdigest,
 description:'One warmup and rotated full-process measurements on a warm filesystem cache. Verification of every path, line, snippet and highlight happens outside timing. No GUI rendering or cold-cache measurements; composition baselines are equivalent on these fixtures. No unrelated tests or builds ran concurrently.',results:report})+"\n")
puts REPORT
