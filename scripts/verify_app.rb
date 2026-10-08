# Check the distributable itself, after moving it away from the source checkout.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
UI_FRAMEWORKS = %r{/(?:AppKit|Cocoa|SwiftUI|SwiftUICore|PDFKit|QuickLookUI|UIKit)\.framework/}
app=ARGV[0] ? File.expand_path(ARGV[0]) : File.expand_path('../dist/FindUI.app',__dir__)
raise "Missing app: #{app}" unless File.directory?(app)
entry,err,status=Open3.capture3('/usr/libexec/PlistBuddy','-c','Print CFBundleExecutable',File.join(app,'Contents/Info.plist'))
raise "Finder must launch the GUI directly: #{err}" unless status.success? && entry.strip=='FindUIApp'
icon,err,status=Open3.capture3('/usr/libexec/PlistBuddy','-c','Print CFBundleIconFile',File.join(app,'Contents/Info.plist'))
raise "Missing app icon: #{err}" unless status.success? && File.file?(File.join(app,'Contents/Resources',icon.strip+'.icns'))
root=Dir.mktmpdir('findui-install-check-')
verified=false
begin
  copy=File.join(root,'FindUI.app')
  out,err,status=Open3.capture3('/usr/bin/ditto',app,copy); raise err unless status.success?
  binary=File.join(copy,'Contents/MacOS/FindUI'); worker=File.join(copy,'Contents/MacOS/findui-content')
  ([binary,worker]+%w[FindUIApp fd rg fzf].map { |n|File.join(copy,"Contents/MacOS",n) }).each do |path|
    raise "Missing executable: #{path}" unless File.executable?(path)
    out,err,status=Open3.capture3('/usr/bin/otool','-L',path); raise err unless status.success?
    dependencies=out.lines.drop(1).map { |line|line.strip.split(' (').first }
    unexpected=dependencies.reject { |path|path.start_with?('/usr/lib/','/System/Library/') }
    raise "External runtime dependencies: #{unexpected.join(', ')}" unless unexpected.empty?
    if path == binary
      ui = dependencies.select { |dependency| dependency.match?(UI_FRAMEWORKS) }
      raise "CLI links UI frameworks: #{ui.join(', ')}" unless ui.empty?
    end
  end
  out,err,status=Open3.capture3('/usr/bin/codesign','--verify','--deep','--strict',copy); raise err unless status.success?
  notices=File.join(copy,'Contents/Resources/Licenses/THIRD_PARTY_NOTICES.txt')
  raise 'Missing bundled license notices' unless File.size?(notices)
  %w[FindUI-LICENSE.txt linguist-LICENSE.txt].each do |name|
    raise "Missing project or data license: #{name}" unless File.size?(File.join(copy,'Contents/Resources/Licenses',name))
  end
  files=File.join(root,'files');FileUtils.mkdir_p(files)
  File.write(File.join(files,'needle.txt'),"needle original\n")
  File.write(File.join(files,'second.md'),"needle nearby\n")
  env={'PATH'=>'/usr/bin:/bin:/usr/sbin:/sbin','FINDUI_CACHE_DIRECTORY'=>File.join(root,'cache'),
       'FINDUI_DATA_DIRECTORY'=>File.join(root,'data'),
       'FINDUI_QUERY_CACHE_DIRECTORY'=>File.join(root,'query-cache'),
       'FINDUI_READER_CONFIG'=>File.join(root,'readers.json'),
       'FINDUI_PRESETS_DIRECTORY'=>File.join(root,'presets'),'FINDUI_TIKA_DIRECTORY'=>File.join(root,'tika'),'FINDUI_TIKA_JAR'=>''}
  File.write(File.join(root,'environment.json'),JSON.pretty_generate(env))
  run=lambda do |*args|
    out,err,status=Open3.capture3(env.merge('DYLD_PRINT_LIBRARIES'=>'1','DYLD_PRINT_TO_FILE'=>nil),binary,'--cli',*args)
    File.open(File.join(root,'commands.jsonl'),'a') { |log| log.puts(JSON.generate({arguments:args,exit:status.exitstatus,stdout:out,stderr:err})) }
    raise "#{args.first(2).join(' ')} failed: #{err}" unless status.success?
    raise 'CLI runtime library trace is unavailable' unless err.match?(%r{^dyld\[\d+\]: .*?/Foundation\.framework/})
    if err.match?(UI_FRAMEWORKS)
      raise "#{args.first(2).join(' ')} loaded a UI framework"
    end
    [out,err]
  end
  state={'query'=>'needle','mode'=>'contents','scopePath'=>files}
  alias_binary=File.join(root,'findui')
  File.symlink(binary,alias_binary)
  command,err,status=Open3.capture3(env,alias_binary,'--cli','search',state.to_json,'--print-command')
  raise "Symlinked CLI lost its bundled tools: #{err}" unless status.success? && command.start_with?(File.join(copy,'Contents/MacOS/rg'))
  # Every CLI command must remain usable without the GUI executable. Also check
  # that a broken GUI installation reports a failure instead of doing nothing.
  # Only this disposable copy is changed, after signature verification. Keep
  # the GUI absent for every remaining installation and backend feature check.
  File.unlink(File.join(copy,'Contents/MacOS/FindUIApp'))
  out,err,status=Open3.capture3(env,binary)
  raise 'Missing GUI has no actionable error' unless status.exitstatus==126 && err.include?('GUI executable is missing')
  out,_=run.call('search',state.to_json);raise 'Live content matches differ' unless out.lines.size==2
  command,_=run.call('search',state.to_json,'--print-command')
  raise 'Plain contents search does not use bundled rg' unless command.start_with?(File.join(copy,'Contents/MacOS/rg'))
  raise 'Search depends on a development worker' if command.include?('.build/content-worker')
  names={'query'=>'needle','mode'=>'files','scopePath'=>files}
  names_command,_=run.call('search',names.to_json,'--print-command')
  raise 'Plain filename search does not use bundled fd' unless names_command.start_with?(File.join(copy,'Contents/MacOS/fd'))
  fuzzy=names.merge('syntax'=>'fuzzy','refinements'=>{'fuzzyFullPath'=>false})
  out,_=run.call('search',fuzzy.to_json)
  raise 'Bundled fuzzy search failed' unless out.split("\0").map { |p|File.basename(p) }==['needle.txt']
  no_hits=state.merge('query'=>'no-such-text')
  out,_=run.call('search',no_hits.to_json);raise 'Empty search is not empty' unless out.empty?
  metadata=JSON.parse(File.read(File.join(copy,'Contents/Resources/BuildInfo.json')))
  %w[ripgrep fd-find fzf].each do |name|
    raise "Missing tool license: #{name}" unless File.size?(File.join(copy,'Contents/Resources/Licenses/SearchTools',name,'THIRD_PARTY_NOTICES.txt'))
  end
  run.call('index','words',state.to_json)
  state['refinements']={'wordSearch'=>true}
  out,_=run.call('search',state.to_json);raise 'Prepared word matches differ' unless out.lines.size==2
  out,_=run.call('index','status',state.to_json);raise 'Coverage is not current' unless JSON.parse(out)['state']=='updated'
  out,_=run.call('suggest',state.to_json,'ne');raise 'Vocabulary unavailable' unless JSON.parse(out).any? { |r|r['text']=='needle' }
  out,_=run.call('facets','search',state.to_json)
  raise 'Facet counts differ' unless JSON.parse(out)['facets'].any? { |r|r['kind']=='fileType' && r['value']=='txt' && r['count']==1 }
  snapshot=File.join(root,'names.sqlite')
  run.call('index','build',{'scopePath'=>files,'name'=>'Installation check'}.to_json,snapshot)
  snapshot_state={'query'=>'needle','mode'=>'files','scopePath'=>files,'useIndex'=>true}
  3.times do |read|
    out,_=run.call('search',snapshot_state.to_json,'--snapshot',snapshot)
    expected=[File.join(files,'needle.txt')]; actual=out.split("\0")
    unless actual==expected
      report={read:read,expected:expected,actual:actual,state:snapshot_state,snapshot:snapshot}
      File.write(File.join(root,'snapshot-mismatch.json'),JSON.pretty_generate(report))
      raise "Snapshot search differs on read #{read+1}: expected #{expected.inspect}, got #{actual.inspect}"
    end
  end
  # Exercise the actual import/export boundary, including rg's emitted Unicode
  # filename type filters. Running an export alone does not test reimporting it.
  command="fd -t f -g '*.txt' -0 | xargs -0 rg -F needle"
  imported,_=run.call('import-command',command,'--directory',files)
  3.times do
    exported,_=run.call('search',imported,'--print-command')
    imported,_=run.call('import-command',exported,'--directory',files)
    recopied,_=run.call('search',imported,'--print-command')
    raise 'Imported command text changed after copying again' unless recopied==exported
    out,_=run.call('search',imported)
    raise 'Imported command round-trip differs' unless out.lines.map { |line|JSON.parse(line).dig('data','path','text') }==[File.join(files,'needle.txt')]
  end
  # Text commands preserve exact stdout and exit status through the packaged
  # CLI, including actions that write no final newline and invalid tool flags.
  action=File.join(files,'action.sh')
  File.write(action,"#!/bin/sh\nprintf x >> calls\nprintf plain\n"); File.chmod(0700,action)
  [
    ['rg --count needle needle.txt', "1\n", 0],
    ['rg --quiet absent needle.txt', '', 1],
    ["fd -t f '^needle\\.txt$' --exec ./action.sh", 'plain', 0],
    ['rg --option-that-does-not-exist needle .', '', 2]
  ].each do |command,expected,code|
    imported,_=run.call('import-command',command,'--directory',files,'--native')
    out,err,status=Open3.capture3(env,binary,'--cli','search',imported)
    raise "Command passthrough differs: #{command}" unless out==expected && status.exitstatus==code
    raise 'Tool diagnostic lost' if code==2 && !err.include?('option-that-does-not-exist')
  end
  raise 'Command action ran more than once' unless File.read(File.join(files,'calls'))=='x'
  File.unlink(action); File.unlink(File.join(files,'calls'))
  puts 'PASS: packaged command passthrough, exact output, tool errors and single execution'
  out,_=run.call('readers'); readers=JSON.parse(out).select { |r|%w[mail sqlite archive].include?(r['id']) }
  raise 'Bundled readers unavailable' unless readers.size==3 && readers.all? { |r|r['ready'] }
  multiline=File.join(files,'span.txt');File.write(multiline,"before\nalpha\nbeta\nafter\n")
  multi={'query'=>'alpha\\nbeta','mode'=>'contents','syntax'=>'regex','scopePath'=>files,'refinements'=>{'multiline'=>true}}
  out,_=run.call('search',multi.to_json)
  raise 'Packaged multiline matching failed' unless out.lines.size==1 && JSON.parse(out)['data']['lines']['text']=="alpha\nbeta\n"
  reader={'id'=>'fixture','title'=>'Fixture reader','extensions'=>['custom'],'executable'=>'/bin/cat','arguments'=>['{path}']}
  run.call('readers','import',[reader].to_json)
  out,_=run.call('readers','export');raise 'Packaged reader management failed' unless JSON.parse(out).first['arguments']==['{path}']
  custom=File.join(files,'source.custom');File.write(custom,"custom reader needle\n")
  custom_state={'query'=>'custom reader','mode'=>'contents','scopePath'=>files,'syntax'=>'literal','refinements'=>{'extraction'=>{'documents'=>false,'archives'=>false,'customReaders'=>true}}}
  out,_=run.call('search',custom_state.to_json)
  raise 'Packaged custom reader failed' unless out.lines.size==1 && JSON.parse(out)['data']['findui_origin']['reader']=='Fixture reader'
  run.call('readers','disable','fixture');run.call('readers','enable','fixture');run.call('readers','remove','fixture')
  out,_=run.call('readers','list');raise 'Packaged reader removal failed' unless JSON.parse(out).empty?
  run.call('cache','retry')
  puts 'PASS: packaged multiline matching, opt-in custom readers and GUI-free reader management/retry'
  provenance=JSON.parse(File.read(File.join(copy,'Contents/Resources/BuildInfo.json')))
  raise 'Missing dependency lock fingerprint' unless provenance.fetch('inputs').key?('Tools/findui-content/Cargo.lock')
  out,_=run.call('benchmark'); report=JSON.parse(out)
  raise 'Packaged benchmark failed' unless report.dig('cache','roundTripVerified') && report['sha256'].size==2
  %w[audit_backend_regressions.rb audit_cli_features.rb audit_command_roundtrips.rb].each do |audit|
    audit_env=env.merge('FINDUI_BINARY'=>binary,'FINDUI_WORKER'=>worker)
    raise "GUI-free #{audit} failed" unless system(audit_env,RbConfig.ruby,File.join(__dir__,audit))
  end
  puts 'PASS: isolated .app, CLI without UI linkage or GUI executable, bundled fd/rg/fzf/worker, signature and licenses'
  puts 'PASS: live search, prepared words, coverage, suggestions, facets, snapshots and compiler-free benchmark'
  puts 'PASS: cold/warm snapshot queries and three command import/export/reimport cycles'
  verified=true
rescue StandardError => error
  warn "Installation check failed: #{error.message}\nPreserved fixture and command logs: #{root}"
  raise
ensure
  FileUtils.remove_entry(root) if verified
end
