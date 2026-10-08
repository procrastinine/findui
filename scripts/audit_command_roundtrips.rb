#!/usr/bin/env ruby
# Execute copied commands and their reimports against the same adversarial
# fixture. Each case repeats three times to expose cumulative translation drift.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
binary=ENV.fetch('FINDUI_BINARY',File.expand_path('../dist/FindUI.app/Contents/MacOS/FindUI',__dir__))
root=Dir.mktmpdir('findui-command-roundtrips-')
passed=false
begin
  files=File.join(root,"files 'quoted' 文"); FileUtils.mkdir_p(files)
  fixtures={'one.swift'=>"alpha beta\nneedle\n",'TWO.SWIFT'=>"ALPHA\nbeta\n",
    '.Hidden.swift'=>"alpha beta\n",'sub/deep.swift'=>"alpha\nbeta\n",'skip/skip.swift'=>"alpha beta\n",
    'one.md'=>"alpha gamma\n",'other.txt'=>"beta\n",'empty.txt'=>'','résumé.txt'=>"café\n",'fold.ſwift'=>"alpha\n",
    "line\nbreak.swift"=>"alpha beta\n",'quote\'s.swift'=>"alpha\n",'ignored.swift'=>"alpha\n",
    '.ignore'=>"ignored.swift\n",'.private/secret.swift'=>"alpha beta\n"}
  fixtures.each { |name,body| path=File.join(files,name);FileUtils.mkdir_p(File.dirname(path));File.binwrite(path,body) }
  tool_dir=File.executable?(File.join(File.dirname(binary),'fd')) ? File.dirname(binary) : File.expand_path('../.build/search-tools/bin',__dir__)
  env={'PATH'=>tool_dir+':/usr/bin:/bin:/usr/sbin:/sbin','FINDUI_CACHE_DIRECTORY'=>File.join(root,'cache'),
       'FINDUI_DATA_DIRECTORY'=>File.join(root,'data'),'FINDUI_QUERY_CACHE_DIRECTORY'=>File.join(root,'query-cache'),
       'FINDUI_TIKA_DIRECTORY'=>File.join(root,'tika'),'FINDUI_TIKA_JAR'=>'','FINDUI_READER_CONFIG'=>File.join(root,'readers.json')}
  run=lambda do |*args|
    out,err,status=Open3.capture3(env,binary,'--cli',*args)
    raise "#{args.first}: #{err}" unless status.success?
    out
  end
  rows=lambda do |out|
    if out.start_with?('{')
      out.lines.filter_map do |line|
        row=JSON.parse(line);next unless row['type']=='match'
        data=row.fetch('data')
        path=data.fetch('path');path={'text'=>File.expand_path(path['text'],files)} if path['text']
        [path,data['line_number'],data['lines'],data['submatches'],data['findui_origin']]
      end.sort_by { |row|JSON.generate(row) }
    else out.split("\0").map { |path|File.expand_path(path,files) }.sort end
  end
  cases=[]; failures=[]
  add=lambda { |name,changes| cases << [name,{'query'=>'one','mode'=>'files','scopePath'=>files,'includeHidden'=>false}.merge(changes)] }
  ['files','folders','everything'].each { |mode| add.call("mode-#{mode}",{'mode'=>mode,'query'=>'*'}) }
  ['one','name:one','ext:swift','path:sub','"quote\'s"','résumé','*.swift','-name:one','one -path:sub',''].each_with_index { |query,i| add.call("filename-#{i}",{'query'=>query}) }
  add.call('filename-regex',{'query'=>'one|TWO','syntax'=>'regex'})
  add.call('filename-exact',{'query'=>'one.swift','exactNameMatch'=>true})
  add.call('filename-fuzzy',{'query'=>'swft','syntax'=>'fuzzy'})
  ['name','path','extensions','excludedFiles'].each { |key| add.call("file-filter-#{key}",{'query'=>'','refinements'=>{key=>key=='extensions' ? 'swift,md' : key=='excludedFiles' ? '*.md' : 'one'}}) }
  filters=JSON.parse(run.call('import-command','fd -t f -0','--directory',files)).fetch('filters')
  add.call('file-size',{'query'=>'*','filters'=>filters.merge('minimumSize'=>'1B','maximumSize'=>'20B')})
  add.call('relative-date',{'query'=>'*','filters'=>filters.merge('datePeriod'=>'week')})
  add.call('file-depth',{'query'=>'*','traversal'=>{'minimumDepth'=>2,'maximumDepth'=>3}})
  add.call('file-prune',{'query'=>'*','traversal'=>{'excludedFolders'=>['skip']}})
  add.call('file-path-rules',{'query'=>'*','traversal'=>{'pathRules'=>['*.swift','!skip']}})
  [false,true].each do |sensitive|
    [false,true].each do |hidden|
      add.call("content-filter-#{sensitive}-#{hidden}",{'query'=>'alpha','mode'=>'contents','includeHidden'=>hidden,
        'caseSensitive'=>sensitive,'refinements'=>{'name'=>'*.swift','nameMatching'=>'glob','fileCaseSensitive'=>sensitive}})
    end
  end
  ['alpha','alpha beta','alpha -beta','"alpha beta"','-alpha'].each_with_index { |query,i| add.call("content-expression-#{i}",{'query'=>query,'mode'=>'contents'}) }
  [
    ['regex',{'syntax'=>'regex','query'=>'alpha|beta'}],
    ['all-lines',{'syntax'=>'regex','query'=>''}],
    ['files-only',{'refinements'=>{'matchingFilesOnly'=>true}}],
    ['whole-words',{'refinements'=>{'wholeWords'=>true}}],
    ['context',{'refinements'=>{'contextLines'=>2}}],
    ['multiline',{'syntax'=>'regex','query'=>'alpha\\nbeta','refinements'=>{'multiline'=>true}}],
    ['encoding',{'refinements'=>{'textEncoding'=>'utf-8'}}],
    ['typo',{'query'=>'alpa','refinements'=>{'typoTolerance'=>1}}],
    ['workers',{'refinements'=>{'workers'=>4}}],
    ['documents',{'refinements'=>{'extraction'=>{'documents'=>true,'archives'=>false,'useTika'=>false}}}],
    ['ignore',{'traversal'=>{'includeIgnored'=>true}}]
  ].each { |name,changes| add.call("content-#{name}",{'query'=>'alpha','mode'=>'contents'}.merge(changes)) }
  commands=["fd -t f -g '*.swift' -0 | xargs -0 rg -F alpha", "fd -t f --and swift -0 | xargs -0 rg -F alpha",
    "find . -type f \\( -name '*.swift' -o -name '*.md' \\) -print0 | xargs -0 rg -F alpha",
    "rg -F -e alpha -e beta .", "rg -F -v -e alpha -e beta .", "rg --files -0 | fzf --read0 --print0 --filter swft",
    "fd -t f -F 'one' -0", "rg --type-add 'findui:*.swift' --type findui --glob '!.*' -e alpha -e beta .",
    "rg --type-add 'findui:résumé.txt' --type findui --glob '!.*' -F café ."]
  commands.each_with_index do |command,i|
    state=JSON.parse(run.call('import-command',command,'--directory',files))
    # Add only machine-readable presentation flags to the original tools.
    oracle=command.gsub('xargs -0 rg ','xargs -0 rg --json ')
    oracle=oracle.sub(/\Arg /,'rg --json ') if oracle.start_with?('rg ') && !oracle.start_with?('rg --files ')
    native,err,status=Open3.capture3(env,'/bin/bash','--noprofile','--norc','-o','pipefail','-c',oracle,chdir:files)
    raise "Original command failed: #{err}" unless status.success? || status.exitstatus==1 && native.empty?
    actual=rows.call(run.call('search',JSON.generate(state)))
    unless rows.call(native)==actual
      failures << {name:"original-tools-#{i}",command:command,expected:rows.call(native),actual:actual}
      warn "FAIL: original-tools-#{i}: imported results differ"
    end
    cases << ["import-#{i}",state]
  end
  ["rg --max-count 1 alpha .", "rg --files-without-match alpha .", "find . \\( -type d -o -name '*.swift' \\) -print0"].each_with_index do |command,i|
    cases << ["native-#{i}",JSON.parse(run.call('import-command',command,'--directory',files,'--native'))]
  end
  # One tree mixes file/content leaves, with arbitrary ALL/ANY/NONE nesting.
  group_template=JSON.parse(run.call('import-command','rg -F -e alpha -e beta .','--directory',files))
  content=lambda { |value| {'rule'=>{'_0'=>{'content'=>{'_0'=>{'literal'=>{'_0'=>value}}}}}} }
  extension=lambda { |value| {'rule'=>{'_0'=>{'file'=>{'_0'=>{'extensions'=>{'_0'=>[value]}}}}}} }
  group=lambda { |kind,*children| {kind=>{'_0'=>children}} }
  trees=[
    group.call('all',content.call('alpha'),content.call('beta')),
    group.call('none',content.call('alpha'),content.call('beta')),
    group.call('all',group.call('any',group.call('all',extension.call('swift'),content.call('alpha')),
      group.call('all',extension.call('md'),content.call('gamma'))),group.call('none',content.call('needle'))),
    group.call('none',group.call('none',group.call('any',content.call('alpha'),extension.call('md'))))]
  trees.each_with_index do |tree,i|
    %w[line document file].each do |unit|
      state=Marshal.load(Marshal.dump(group_template));state.delete('sourceCommand')
      state['criteria']['grouped']['_0']={'expression'=>tree,'contentUnit'=>unit}
      cases << ["nested-#{i}-#{unit}",state]
    end
  end
  manifest=File.join(root,'results.nul');File.binwrite(manifest,File.join(files,'one.swift')+"\0")
  add.call('saved-results',{'query'=>'alpha','mode'=>'contents','resultScope'=>{'path'=>manifest,'name'=>'Fixture selection','count'=>1}})
  words={'query'=>'alpha','mode'=>'contents','scopePath'=>files,'includeHidden'=>false,'refinements'=>{'wordSearch'=>true}}
  run.call('index','words',JSON.generate(words))
  cases << ['prepared-words',words]
  cases << ['prepared-words-files',words.merge('refinements'=>{'wordSearch'=>true,'matchingFilesOnly'=>true})]
  cases << ['prepared-words-stems',words.merge('refinements'=>{'wordSearch'=>true,'stemWords'=>true})]
  [['search',['--stats']],['browse',[]],['browse',['--stats']]].each do |action,options|
    source={'query'=>'one','mode'=>'files','scopePath'=>files,'includeHidden'=>false}
    copied=run.call(action,JSON.generate(source),*options,'--print-command')
    restored=JSON.parse(run.call('import-command',copied,'--directory',files))
    raise 'Request options changed the copied command after import' unless run.call('search',JSON.generate(restored),'--print-command')==copied
    raise 'Request options changed the search results after import' unless rows.call(run.call('search',JSON.generate(restored)))==rows.call(run.call(action,JSON.generate(source),*options))
    cases << ["request-options-#{action}-#{options.join}",restored]
  end
  snapshot=File.join(root,'names.sqlite')
  run.call('index','build',JSON.generate('scopePath'=>files,'includeHidden'=>false),snapshot)
  %w[search browse].each do |action|
    state={'query'=>'one','mode'=>'files','scopePath'=>files,'useIndex'=>true,'includeHidden'=>false}
    copied=run.call(action,JSON.generate(state),'--snapshot',snapshot,'--print-command')
    restored=JSON.parse(run.call('import-command',copied,'--directory',files))
    raise 'Snapshot command text changed after import' unless run.call('search',JSON.generate(restored),'--print-command')==copied
    raise 'Snapshot import changed its results' unless rows.call(run.call('search',JSON.generate(restored)))==rows.call(run.call(action,JSON.generate(state),'--snapshot',snapshot))
    cases << ["snapshot-#{action}",restored]
  end
  cases.each do |name,state|
    command=nil; original=Marshal.load(Marshal.dump(state))
    begin
      expected=rows.call(run.call('search',JSON.generate(state)))
      3.times do |cycle|
        command=run.call('search',JSON.generate(state),'--print-command')
        copied,err,status=Open3.capture3(env,'/bin/bash','--noprofile','--norc','-c',command)
        raise "Copied command failed: #{err}" unless status.success? || status.exitstatus==1 && copied.empty?
        raise "Copied results differ at cycle #{cycle}" unless rows.call(copied)==expected
        state=JSON.parse(run.call('import-command',command,'--directory',files))
        recopied=run.call('search',JSON.generate(state),'--print-command')
        raise "Copied command text changed at cycle #{cycle}:\n#{command}\nBECAME\n#{recopied}" unless recopied==command
        actual=rows.call(run.call('search',JSON.generate(state)))
        raise "Reimported results differ at cycle #{cycle}: expected #{expected.inspect}, actual #{actual.inspect}" unless actual==expected
      end
      puts "PASS: #{name}"
    rescue => error
      warn "FAIL: #{name}: #{error.message}"
      failures << {name:name,error:error.message,original:original,state:state,command:command}
    end
  end
  File.write(File.join(root,'report.json'),JSON.pretty_generate({cases:cases.size,cycles:3,failures:failures}))
  raise "#{failures.size} command round-trip failures; fixture/report retained: #{root}" unless failures.empty?
  puts "PASS: #{cases.size} cases, #{cases.size*3} export/execute/reimport cycles with identical commands and results"
  passed=true
ensure
  FileUtils.remove_entry(root) if passed
end
