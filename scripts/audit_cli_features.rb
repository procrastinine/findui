#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
binary=ENV.fetch('FINDUI_BINARY',File.expand_path('../dist/FindUI.app/Contents/MacOS/FindUI',__dir__))
Dir.mktmpdir('findui-cli-features-') do |temporary|
  root=File.realpath(temporary)
  env={'FINDUI_PRESETS_DIRECTORY'=>File.join(root,'presets'),'FINDUI_CACHE_DIRECTORY'=>File.join(root,'cache'),
       'FINDUI_TIKA_DIRECTORY'=>File.join(root,'tika'),'FINDUI_TIKA_JAR'=>''}
  run=lambda do |*args|
    out,err,status=Open3.capture3(env,binary,'--cli',*args)
    raise "#{args.take(2)}: #{err}" unless status.success?
    [out,err]
  end
  files=File.join(root,'files'); FileUtils.mkdir_p(files)
  found=File.join(files,'found.txt'); other=File.join(files,'other.txt')
  File.write(found,("ordinary log record\n"*20_000)+"needle\n"); File.write(other,"needle\n")
  state={'query'=>'needle','mode'=>'contents','scopePath'=>files}
  saved=JSON.parse(run.call('presets','save','search','Needle',JSON.generate(state))[0])
  raise 'Wrong saved preset' unless saved['name']=='Needle' && saved['kind']=='search'
  applied=JSON.parse(run.call('presets','apply',saved['id'],JSON.generate(state.merge('query'=>'absent')))[0])
  raise 'Preset apply lost query' unless applied['query']=='needle'
  catalog=JSON.parse(run.call('presets','export')[0]); run.call('presets','import',JSON.generate(catalog))
  imported=JSON.parse(run.call('presets','list')[0])['presets']
  raise 'Import overwrote the original' unless imported.size==2 && imported.map { |p|p['id'] }.uniq.size==2
  run.call('presets','remove',imported.last['id'])
  run.call('index','contents',JSON.generate(state))
  output,stats=run.call('search',JSON.generate(state),'--stats')
  raise 'CLI stats missing' unless stats.include?('findui-stats: ')
  rows=output.lines.map { |line|JSON.parse(line) }
  raise "Search failed: #{output.inspect}; #{stats}" unless rows.map { |row|File.realpath(row['data']['path']['text']) }.sort==[found,other].sort
  manifest=File.join(root,'results.nul'); File.binwrite(manifest,found+"\0")
  output,=run.call('search',JSON.generate(state),'--within',manifest)
  raise "Result refinement differs: #{output.inspect}, expected #{found}" unless output.lines.map { |l|File.realpath(JSON.parse(l)['data']['path']['text']) }==[found]
  command,=run.call('search',JSON.generate(state),'--within',manifest,'--print-command')
  copied,err,status=Open3.capture3(env,'/bin/bash','--noprofile','--norc','-c',command)
  raise "Copied command differs: #{err}" unless status.success? && copied==output
  File.write(other,"needle connecting\n")
  run.call('index','words',JSON.generate(applied))
  words=Marshal.load(Marshal.dump(applied)); words['query']='connect'
  words['refinements'].merge!('wordSearch'=>true,'stemWords'=>true)
  output,=run.call('search',JSON.generate(words))
  raise "Prepared word stemming failed: #{output.inspect}" unless output.lines.map { |l|File.realpath(JSON.parse(l)['data']['path']['text']) }==[other]
  words['refinements']['matchingFilesOnly']=true
  output,=run.call('search',JSON.generate(words))
  raise 'Word files-only output differs' unless output.split("\0").map { |p|File.realpath(p) }==[other]
  command,=run.call('search',JSON.generate(words),'--print-command')
  copied,err,status=Open3.capture3(env,'/bin/bash','--noprofile','--norc','-c',command)
  raise "Copied word command differs: #{err}" unless status.success? && copied==output && command.include?('Contents/MacOS/findui-content')
  index=File.join(root,'index.sqlite')
  run.call('index','build',JSON.generate('scopePath'=>files),index)
  raise 'Snapshot is not SQLite' unless File.binread(index,16)=="SQLite format 3\0"
  exported=JSON.parse(run.call('index','export',index)[0])
  raise 'Snapshot export missing entries' unless exported['entries'].size==2
  output,=run.call('search',JSON.generate(state.merge('query'=>'found','mode'=>'files')),'--snapshot',index)
  raise 'Packaged snapshot query differs' unless output.split("\0").map { |p|File.realpath(p) }==[found]
  explanation=JSON.parse(run.call('explain',JSON.generate(state),found)[0])
  raise 'Explain disagrees with search' unless explanation['steps'].all? { |s|s['passed'] }
  old=File.join(files,'old.txt'); File.binwrite(old,"caf\xe9 needl\n".b)
  encoded=Marshal.load(Marshal.dump(applied));encoded['refinements'].merge!('textEncoding'=>'windows-1252','typoTolerance'=>1)
  output,=run.call('search',JSON.generate(encoded))
  raise 'Legacy encoding/typo match missing' unless output.lines.any? { |l|JSON.parse(l)['data']['lines']['text']=="café needl\n" }
  preview=JSON.parse(run.call('text','preview',JSON.generate('path'=>old,'line'=>1,'encoding'=>'windows-1252','expectedSnippet'=>'café needl'))[0])
  raise 'Preview decoder differs from search' unless preview['lines'][0]['text']=='café needl' && preview['warning'].nil?
  database=File.join(files,'records')
  _,err,status=Open3.capture3('/usr/bin/sqlite3',database,"CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES(1,'databaseneedle');")
  raise err unless status.success?
  documents=Marshal.load(Marshal.dump(applied));documents['query']='databaseneedle'
  documents['refinements']['extraction']={'documents'=>true,'archives'=>false,'useTika'=>false}
  output,=run.call('search',JSON.generate(documents))
  row=JSON.parse(output.lines.first)
  raise 'SQLite provenance missing' unless row.dig('data','findui_origin','table')=='notes' && row.dig('data','findui_origin','row')=='1'
  email=File.join(files,'email.eml')
  File.write(email,"From: sender@example.org\r\nSubject: fixture\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=X\r\n\r\n--X\r\nContent-Type: text/plain\r\n\r\nbody\r\n--X\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=notes.txt\r\nContent-Transfer-Encoding: base64\r\n\r\nYXR0YWNobmVlZGxlCg==\r\n--X--\r\n")
  documents['query']='attachneedle'
  raise 'Attachments expanded without opt-in' unless run.call('search',JSON.generate(documents))[0].empty?
  documents['refinements']['extraction']['archives']=true
  output,=run.call('search',JSON.generate(documents));row=JSON.parse(output.lines.first)
  origin=row.dig('data','findui_origin');raise 'Email attachment provenance missing' unless origin['members'][0]['kind']=='mail'
  location={'path'=>email,'origin'=>origin,'extraction'=>documents['refinements']['extraction']}
  materialized=JSON.parse(run.call('document','materialize',JSON.generate(location))[0])['path']
  begin
    raise 'Attachment bytes or extension lost' unless File.read(materialized)=="attachneedle\n" && File.extname(materialized)=='.txt'
  ensure
    File.unlink(materialized)
  end
  puts 'PASS: packaged ranked/stemmed words, files-only/copy parity, SQLite snapshot/export, explain, encoding/typo/context parity, SQLite row provenance and opt-in email attachments'
  run.call('cache','clear')
  raise 'Cache remained after clear' if File.exist?(env['FINDUI_CACHE_DIRECTORY'])
  puts 'PASS: packaged CLI presets save/apply/import/export/remove, content preparation/statistics, full-file refinement, copied command parity and cache clear; isolated stores'
end
