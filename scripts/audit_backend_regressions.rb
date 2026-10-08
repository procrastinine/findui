#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

binary = ENV.fetch('FINDUI_BINARY', File.expand_path('../dist/FindUI.app/Contents/MacOS/FindUI', __dir__))
worker = ENV.fetch('FINDUI_WORKER', File.join(File.dirname(binary), 'findui-content'))
defaults = {'additionalScopes'=>[], 'source'=>'filesystem', 'name'=>'', 'nameMatching'=>'contains',
  'path'=>'', 'pathMatching'=>'contains', 'extensions'=>'', 'excludedFiles'=>'', 'fileQuery'=>'',
  'wholeWords'=>false, 'matchingFilesOnly'=>false, 'contextLines'=>3, 'fuzzyFullPath'=>true}

Dir.mktmpdir('findui-regressions-') do |temporary|
  root = File.realpath(temporary)
  env = {'FINDUI_CACHE_DIRECTORY'=>File.join(root,'cache'), 'FINDUI_TIKA_DIRECTORY'=>File.join(root,'tika'), 'FINDUI_TIKA_JAR'=>''}
  run = lambda do |*args|
    out, err, status = Open3.capture3(env, binary, '--cli', *args)
    raise "#{args.take(2)}: #{err}" unless status.success?
    out
  end
  search = lambda do |state, *options|
    out = run.call('search', JSON.generate(state), *options)
    unless options.include?('--snapshot')
      command = run.call('search', JSON.generate(state), *options, '--print-command')
      copied, err, status = Open3.capture3(env, '/bin/bash', '--noprofile', '--norc', '-c', command)
      normalize=lambda do |text|
        if text.start_with?('{')
          text.lines.map { |line|JSON.parse(line) }.select { |r|r['type']=='match' }.map { |r|JSON.generate(r.sort.to_h) }.sort
        else
          text.split("\0").sort
        end
      end
      raise "Copied command disagrees: #{err}" unless [0,1].include?(status.exitstatus) && normalize.call(copied)==normalize.call(out)
    end
    out
  end
  files = File.join(root, 'files'); FileUtils.mkdir_p(File.join(files,'.kept'))
  kept = File.join(files,'.kept/document.txt'); File.write(kept,"needle\n")
  File.write(File.join(files,'.ignore'),"!.kept/\n!.kept/**\n")
  state = {'query'=>'needle','mode'=>'contents','scopePath'=>files,'includeHidden'=>false,'refinements'=>defaults.dup}
  snapshot = File.join(root,'snapshot.sqlite')
  [false,true].each do |hidden|
    state['includeHidden'] = hidden
    expected = hidden ? [kept] : []
    [false,true].each do |filtered|
      state['refinements']['name'] = filtered ? '.txt' : ''
      rows = search.call(state).lines.map { |l|JSON.parse(l) }
      actual = rows.map { |r|File.realpath(r.dig('data','path','text')) }
      raise "Hidden setting changed after filtering: hidden=#{hidden}, filtered=#{filtered}" unless actual == expected
    end
    run.call('index','words',JSON.generate(state))
    state['refinements']['wordSearch'] = true
    rows = search.call(state).lines.map { |l|JSON.parse(l) }
    raise "Word index disagrees with Include hidden=#{hidden}" unless rows.map { |r|File.realpath(r.dig('data','path','text')) } == expected
    state['refinements'].delete('wordSearch')
    run.call('index','build',JSON.generate('scopePath'=>files,'includeHidden'=>hidden),snapshot)
    frozen_state = state.merge('query'=>'document','mode'=>'files')
    actual = search.call(frozen_state,'--snapshot',snapshot).split("\0").map { |p|File.realpath(p) }
    raise "Snapshot disagrees with Include hidden=#{hidden}" unless actual == expected
  end
  frozen = state.merge('query'=>'document','mode'=>'files')
  File.unlink(kept)
  report = JSON.parse(run.call('explain',JSON.generate(frozen),kept,'--snapshot',snapshot))
  raise "Explicit snapshot explanation disagrees: #{report}" unless report['steps'].first['title']=='Snapshot' && report['steps'].all? { |s|s['passed'] }
  puts 'PASS: Include hidden on/off with ignore whitelists, filters, words and snapshots; deleted-file explanation and copied-command parity'

  plain = File.join(files,'plain.txt'); File.write(plain,"needle\n")
  within = File.join(root,'within.nul'); File.binwrite(within,plain+"\0")
  File.write(File.join(files,'.ignore'),"plain.txt\n")
  state['refinements']['name']=''
  raise 'Saved results bypassed current ignore rules' unless search.call(state,'--within',within).empty?
  puts 'PASS: saved-result searches apply current ignore rules'

  member = File.join(root,'needle.txt'); File.write(member,"Haystack only.\n")
  archive = File.join(root,'source.zip')
  _,err,status = Open3.capture3('/usr/bin/zip','-q',archive,'needle.txt',chdir:root); raise err unless status.success?
  control = File.join(root,'control.txt'); File.write(control,"before\x01after needle tail\x02\n")
  plan = {'leaves'=>[{'pattern'=>'needle'}],'tree'=>{'leaf'=>0},'positive'=>[0],'indexDirectory'=>File.join(root,'words'),
    'extraction'=>{'documents'=>false,'archives'=>true,'maxDepth'=>5,'maxMegabytes'=>8,'timeoutSeconds'=>10}}
  _,err,status = Open3.capture3(env,worker,'--prepare-words',JSON.generate(plan),stdin_data:[archive,control].join("\0")+"\0")
  raise err unless status.success?
  out,err,status = Open3.capture3(env,worker,'--word-matches',JSON.generate(plan)); raise err unless status.success?
  rows = out.lines.map { |l|JSON.parse(l) }
  raise 'Indexed body matched member name' unless rows.size==1 && rows[0].dig('data','path','text')==control
  data=rows[0]['data']
  raise 'Indexed highlight altered source bytes' unless data.dig('lines','text')==File.read(control) && data['submatches'][0]['start']==13
  puts 'PASS: packaged word index keeps body/member matching distinct and preserves snippet bytes/offsets'

  corpus = ['', "\n", "alpha\n", "beta\n", "alpha beta\n", "alpha\nbeta\n", "noise\n", "alpha\nnoise\n", "beta\nnoise\n"]
  paths = corpus.each_with_index.map { |text,i| path=File.join(root,"case#{i}.txt"); File.write(path,text); path }
  leaves=[{'pattern'=>'alpha'},{'pattern'=>'beta'}]
  trees=[{'leaf'=>0},{'all'=>[{'leaf'=>0},{'leaf'=>1}]},{'any'=>[{'leaf'=>0},{'leaf'=>1}]},
    {'none'=>[{'leaf'=>0}]},{'all'=>[{'leaf'=>0},{'none'=>[{'leaf'=>1}]}]}]
  evaluate = lambda do |tree, mask|
    if tree.key?('leaf'); mask[tree['leaf']]
    elsif tree.key?('all'); tree['all'].all? { |t|evaluate.call(t,mask) }
    elsif tree.key?('any'); tree['any'].any? { |t|evaluate.call(t,mask) }
    else; !tree['none'].any? { |t|evaluate.call(t,mask) }; end
  end
  count=0
  [1,4].product([false,true],trees).each do |threads,whole,tree|
    query={'leaves'=>leaves,'tree'=>tree,'positive'=>[0,1],'filesOnly'=>true,'fileUnit'=>whole,'threads'=>threads}
    out,err,status=Open3.capture3(env,worker,'--plan',JSON.generate(query),stdin_data:paths.join("\0")+"\0")
    raise err unless status.success?
    expected=paths.each_with_index.select do |path,i|
      units=whole ? [corpus[i]] : corpus[i].lines
      units.any? { |unit|evaluate.call(tree,leaves.map { |l|unit.include?(l['pattern']) }) }
    end.map(&:first).sort
    raise "Boolean membership differs from oracle: #{query}" unless out.split("\0").sort==expected
    count+=1
  end
  puts "PASS: #{count} Boolean queries checked against an independent oracle, with 1 and 4 workers"

  tree = File.join(root,'tree')
  %w[keep .hidden .kept depth/a/b Sample.app/inside blocked].each do |name|
    FileUtils.mkdir_p(File.join(tree,name)); File.write(File.join(tree,name,'file.txt'),'needle')
  end
  File.write(File.join(tree,'.ignore'),"blocked/\n!.kept/\n!.kept/**\n")
  File.symlink(File.join(tree,'keep/file.txt'),File.join(tree,'link.txt'))
  File.symlink(File.join(tree,'keep'),File.join(tree,'linked'))
  candidates = Dir.glob(File.join(tree,'**/*'),File::FNM_DOTMATCH).reject { |p| ['.','..'].include?(File.basename(p)) }
  candidates += [tree,File.join(tree,'linked/file.txt')]
  comparisons=0
  [0,1,3].product([false,true],[false,true],[false,true],%w[both f d]).each do |minimum,hidden,follow,packages,kind|
    configuration={'roots'=>[tree,File.join(tree,'Sample.app/inside')], 'minimumDepth'=>minimum,'maximumDepth'=>4,
      'hidden'=>hidden,'follow'=>follow,'packages'=>packages,'packageExtensions'=>['app'],'kind'=>kind,'threads'=>4}
    walked,err,status=Open3.capture3(env,worker,'--walk',JSON.generate(configuration)); raise err unless status.success?
    admitted,err,status=Open3.capture3(env,worker,'--admit',JSON.generate(configuration),stdin_data:candidates.join("\0")+"\0"); raise err unless status.success?
    raise "Walk/admission mismatch: #{configuration}\nwalk=#{walked.split("\0").sort}\nadmit=#{admitted.split("\0").sort}" unless walked.split("\0").uniq.sort==admitted.split("\0").uniq.sort
    comparisons+=1
  end
  puts "PASS: #{comparisons} traversal/admission comparisons covering depth, hidden overrides, symlinks, packages and overlapping roots"
end
