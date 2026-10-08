#!/usr/bin/env ruby
# Deterministic backend parity and acceleration audit. No network, gems or GUI.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require 'digest'
require_relative 'tool_paths'

WORKER = ENV.fetch('FINDUI_CONTENT', File.expand_path('../.build/content-worker/release/findui-content', __dir__))
def check(value, message); raise message unless value; end
def execute(plan, paths)
  before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, err, status = Open3.capture3(WORKER, '--plan', JSON.generate(plan), stdin_data: paths.join("\0") + "\0")
  check(status.success?, err)
  stats = err.lines.find { |line| line.start_with?('findui-stats: ') }
  [out, stats && JSON.parse(stats.delete_prefix('findui-stats: ')), Process.clock_gettime(Process::CLOCK_MONOTONIC) - before]
end
def rows(out); out.lines.map { |line| JSON.parse(line) }; end
def query(pattern, extra = {})
  {'leaves'=>[{'pattern'=>pattern}], 'tree'=>{'leaf'=>0}, 'positive'=>[0], 'stats'=>true, 'threads'=>4}.merge(extra)
end
def zip(path, entries)
  data = ''.b; central = ''.b
  entries.each do |name, content|
    name = name.b; content = content.b; offset = data.bytesize; crc = Zlib.crc32(content)
    data << [0x04034b50,20,0x800,0,0,0,crc,content.bytesize,content.bytesize,name.bytesize,0].pack('VvvvvvVVVvv') << name << content
    central << [0x02014b50,20,20,0x800,0,0,0,crc,content.bytesize,content.bytesize,name.bytesize,0,0,0,0,0,offset].pack('VvvvvvvVVVvvvvvVV') << name
  end
  offset=data.bytesize; data << central << [0x06054b50,0,0,entries.size,entries.size,central.bytesize,offset,0].pack('VvvvvVVv')
  File.binwrite(path,data)
end
def pdf(path)
  streams=['first page only','needle second page'].map { |s| "BT /F1 16 Tf 72 720 Td (#{s}) Tj ET\n" }
  objects=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>']
  2.times { |i| objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents #{i+6} 0 R >>" }
  objects << '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  streams.each { |s| objects << "<< /Length #{s.bytesize} >>\nstream\n#{s}endstream" }
  objects << '<< /Title (Research & Notes) /Author (Ada & Bob) >>'
  data="%PDF-1.4\n"; offsets=[0]
  objects.each_with_index { |object,i| offsets << data.bytesize; data << "#{i+1} 0 obj\n#{object}\nendobj\n" }
  xref=data.bytesize; data << "xref\n0 #{objects.length+1}\n0000000000 65535 f \n"
  offsets.drop(1).each { |offset| data << format('%010d 00000 n ',offset) + "\n" }
  data << "trailer\n<< /Size #{objects.length+1} /Root 1 0 R /Info 8 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  File.binwrite(path,data)
end

Dir.mktmpdir('findui-content-audit-') do |temp|
  root = File.realpath(temp)
  cache = File.join(root,'cache')
  extraction = {'documents'=>true,'archives'=>true,'cacheDirectory'=>cache,'maxDepth'=>5,'maxMegabytes'=>64,
    'timeoutSeconds'=>30,'pandoc'=>findui_tool('pandoc'),'pdftotext'=>findui_tool('pdftotext')}
  archive = File.join(root,'odd archive.zip')
  entries = [["nested/alpha : \n'雪.txt", "alpha one\nbeta\n"], ['duplicate.txt',"alpha\n"], ['duplicate.txt',"beta\n"], ['../../escape.txt',"safe needle\n"]]
  zip(archive,entries)
  plan=query('alpha',{'extraction'=>extraction})
  first, stats, = execute(plan,[archive]); check(stats['documentsConverted']==1,'Archive was not converted once')
  warm, stats, = execute(plan,[archive]); check(first==warm && stats['documentCacheHits']==1,'Archive cache did not retain identical rows')
  disabled = query('alpha', {'extraction'=>extraction.merge('archives'=>false)})
  skipped, stats, = execute(disabled, [archive])
  check(skipped.empty? && stats['filesOpened']==0 && stats['documentCacheHits']==0, 'Disabled expansion read an archive or reused its expanded contents')
  _, stats, = execute(disabled.merge('indexOnly'=>true), [archive])
  check(stats['filesOpened']==0 && stats['documentsConverted']==0 && stats['indexesUpdated']==0, 'Content preparation silently enabled archive expansion')
  puts 'PASS: disabled archive expansion skips payloads and cached member contents during search and index preparation'
  names = query('duplicate', {'archiveNamesOnly'=>true,'indexDirectory'=>cache,'leaves'=>[{'pattern'=>'duplicate','field'=>'member'}]})
  named, stats, = execute(names, [archive])
  check(rows(named).size==2 && stats['documentsConverted']==0 && stats['archiveDirectoriesRead']==1, 'ZIP name listing lost duplicates or decompressed contents')
  check(rows(named).all? { |row|row['data']['findui_origin']['metadataOnly']==true && row['data']['lines']['text'].strip.empty? }, 'Name-only results invented body text')
  _,stats,=execute(names,[archive]); check(stats['archiveDirectoriesRead']==0 && stats['documentCacheHits']==1, 'ZIP name listing repeated unchanged directory reads')
  # Keep a valid directory, but make the first payload impossible to decode.
  # Mark it as a compressed Unix symlink too: general-purpose header readers
  # can decompress symlink targets even during a listing.
  damaged=File.join(root,'names-only.zip'); zip(damaged, [['directory/', ''], ['directory/secret.txt', 'broken compressed data']])
  bytes=File.binread(damaged); local=bytes.index("PK\x03\x04",4); central=bytes.index("PK\x01\x02",bytes.index("PK\x01\x02")+4)
  bytes[local+8,2]=[8].pack('v'); bytes[central+10,2]=[8].pack('v')
  bytes[central+4,2]=[(3<<8)|20].pack('v'); bytes[central+38,4]=[(0120777<<16)].pack('V'); File.binwrite(damaged,bytes)
  all_names=names.merge('leaves'=>[{'pattern'=>'directory','field'=>'member'}])
  named,stats,=execute(all_names,[damaged]); check(rows(named).size==2 && stats['documentsConverted']==0, 'Name listing tried to inflate a corrupt symlink payload')
  check(rows(named).any? { |row|row['data']['findui_origin']['memberKind']=='directory' }, 'ZIP directory names missing')
  puts 'PASS: ZIP directory-only queries preserve duplicate names, cache metadata, include folders and never decode even corrupt compressed symlink payloads'
  all=rows(first); origin=all.first['data']['findui_origin']
  check(all.map { |r|r['data']['findui_origin']['members'].last['name'] }==entries.take(2).map(&:first),'Member identity lost unusual or duplicate names')
  check(all.none? { |r|r['data']['lines']['text'].include?('nested/') },'Member names polluted document text')
  both = query('',{'extraction'=>extraction,'fileUnit'=>true,'documentUnit'=>true,'leaves'=>[{'pattern'=>'alpha'},{'pattern'=>'beta'}], 'positive'=>[0,1], 'tree'=>{'all'=>[{'leaf'=>0},{'leaf'=>1}]}})
  matches=rows(execute(both,[archive])[0]); check(matches.size==1 && matches.first['data']['findui_origin']['members'].last['index']==0,'AND crossed archive members')
  near=both.merge('fileUnit'=>false,'leaves'=>[{'terms'=>['alpha','beta'],'distance'=>1,'ordered'=>true}],'tree'=>{'leaf'=>0},'positive'=>[0])
  check(rows(execute(near,[archive])[0]).size==1,'Proximity failed across lines or crossed member boundaries')
  far=near.merge('leaves'=>[{'terms'=>['alpha','beta'],'distance'=>0,'ordered'=>true}])
  check(execute(far,[archive])[0].empty?,'Proximity ignored intervening words')
  member=query('escape',{'extraction'=>extraction,'leaves'=>[{'pattern'=>'escape','field'=>'member'}]})
  chosen=rows(execute(member,[archive])[0]).first
  check(chosen && chosen['data']['findui_origin']['members'].last['name']=='../../escape.txt','Signature excluded member metadata')
  request={'path'=>archive,'origin'=>chosen['data']['findui_origin'],'extraction'=>extraction,'context'=>2,'expectedSnippet'=>'safe needle'}
  materialized, err, status=Open3.capture3(WORKER,'--materialize-member',JSON.generate(request))
  check(status.success?,err); file=JSON.parse(materialized)['path']; check(File.read(file)=="safe needle\n",'Wrong archive member materialized'); File.unlink(file)
  preview, err, status=Open3.capture3(WORKER,'--document-preview',JSON.generate(request))
  check(status.success? && JSON.parse(preview)['lines'].first['text']=='safe needle',"Cached preview failed: #{err}")
  duplicate=query('beta',{'extraction'=>extraction})
  chosen=rows(execute(duplicate,[archive])[0]).find { |r|r['data']['findui_origin']['members'].last['index']==2 }
  request['origin']=chosen['data']['findui_origin']; request.delete('expectedSnippet')
  materialized,err,status=Open3.capture3(WORKER,'--materialize-member',JSON.generate(request))
  check(status.success?,err); file=JSON.parse(materialized)['path']; check(File.read(file)=="beta\n",'Duplicate member name opened the wrong entry'); File.unlink(file)
  zip(archive,entries.reverse)
  _,_,status=Open3.capture3(WORKER,'--materialize-member',JSON.generate(request)); check(!status.success?,'Stale archive identity accepted')
  puts 'PASS: typed member names, duplicate/path-traversal names, per-member AND, cross-line proximity, cached preview, safe open, stale identities'

  markdown=File.join(root,'source.md'); File.write(markdown,"---\ntitle: 'A & B title'\nauthor: 'Ada & Bob'\n---\n\ncontent needle\n")
  docx=File.join(root,'title.docx')
  _,err,status=Open3.capture3(findui_tool('pandoc'),markdown,'-o',docx); check(status.success?,err)
  title=query('A & B',{'extraction'=>extraction,'leaves'=>[{'pattern'=>'A & B','field'=>'title'}]})
  record=rows(execute(title,[docx])[0]).first
  check(record && record['data']['findui_origin']['documentTitle']=='A & B title','DOCX title metadata or XML entity decode failed')
  author=title.merge('leaves'=>[{'pattern'=>'Ada & Bob','field'=>'author'}])
  check(!execute(author,[docx])[0].empty?,'DOCX author failed with warm cache')
  puts 'PASS: DOCX title and author fields with XML entities, cached metadata queries'
  pdf_file=File.join(root,'two pages.pdf'); pdf(pdf_file)
  found=rows(execute(query('needle',{'extraction'=>extraction}),[pdf_file])[0]).first
  check(found && found['data']['findui_origin']['page']==2,'PDF page location is wrong')
  check(found['data']['findui_origin']['documentTitle']=='Research & Notes' && found['data']['findui_origin']['author']=='Ada & Bob','PDF metadata was lost')
  preview,err,status=Open3.capture3(WORKER,'--document-preview',JSON.generate({'path'=>pdf_file,'origin'=>found['data']['findui_origin'],'extraction'=>extraction}))
  check(status.success? && JSON.parse(preview)['lines'].any? { |line|line['isMatch'] && line['text'].include?('second page') },"PDF cached context mismatch: #{err}")
  File.write(File.join(root,'package.txt'),"needle package\n")
  seven=File.join(root,'package.7z')
  _,err,status=Open3.capture3('/usr/bin/tar','--format=7zip','-cf',seven,'-C',root,'package.txt'); check(status.success?,err)
  check(rows(execute(query('needle',{'extraction'=>extraction}),[seven])[0]).size==1,'7z member missing')
  _,err,status=Open3.capture3('/usr/bin/tar','-czf',File.join(root,'Payload'),'-C',root,'package.txt'); check(status.success?,err)
  pkg=File.join(root,'installer.pkg')
  _,err,status=Open3.capture3('/usr/bin/tar','--format=xar','-cf',pkg,'-C',root,'Payload'); check(status.success?,err)
  found=rows(execute(query('needle',{'extraction'=>extraction}),[pkg])[0]).first
  check(found && found['data']['findui_origin']['members'].map { |m|m['name'] }==['Payload','package.txt'],'Extensionless installer payload was missed')
  puts 'PASS: real PDF page 2 and metadata, cached context, 7z, XAR installer with extensionless compressed payload'
  parts,err,status=Open3.capture3('/usr/bin/unzip','-Z1',docx); check(status.success?,err)
  parts=parts.lines.map(&:chomp).reject { |name|name.end_with?('/') }.map do |name|
    pattern=name.gsub(/[\\*?\[\]]/) { |character| "\\#{character}" }
    bytes,err,status=Open3.capture3('/usr/bin/unzip','-p',docx,pattern); check(status.success?,err); [name,bytes]
  end
  zip(docx,parts)
  check(!execute(query('needle',{'extraction'=>extraction}),[docx])[0].empty?,'Baseline stored DOCX missing')
  stamp=File.mtime(docx); size=File.size(docx)
  zip(docx,parts.map { |name,bytes|[name,name=='word/document.xml' ? bytes.gsub('needle','marker') : bytes] }); File.utime(stamp,stamp,docx)
  check(File.size(docx)==size,'Stale-document fixture must retain file size')
  check(!execute(query('marker',{'extraction'=>extraction}),[docx])[0].empty?,'Same-size DOCX edit reused stale conversion')
  check(execute(query('needle',{'extraction'=>extraction}),[docx])[0].empty?,'Old DOCX contents leaked through another cache')
  uncached=File.join(root,'unowned-cache'); FileUtils.mkdir_p(uncached); File.write(File.join(uncached,'keep'),'keep')
  check(!execute(query('marker',{'extraction'=>extraction.merge('cacheDirectory'=>uncached)}),[docx])[0].empty?,'Cache failure hid document results')
  check(File.read(File.join(uncached,'keep'))=='keep','Fallback modified unrelated cache files')
  puts 'PASS: same-size document edits with restored mtime, no second stale cache, unavailable-cache fallback'

  # Sparse, repetitive logs are a useful workload for a conservative signature.
  # Record all timings rather than asserting hardware-dependent speed ratios.
  paths=32.times.map do |i|
    path=File.join(root,"log-#{i}.txt")
    File.write(path,("INFO record #{i} status ordinary payload item\n" * 50_000) + (i==17 ? "uniqueneedle seventeen\n" : ''))
    path
  end
  plan=query('uniqueneedle',{'indexDirectory'=>cache})
  _,cold_stats,cold_time=execute(plan.merge('indexOnly'=>true),paths)
  cold,_,=execute(plan,paths)
  warm,warm_stats,warm_time=execute(plan,paths)
  baseline,_,baseline_time=execute(plan.reject { |k,_| k=='indexDirectory' },paths)
  indexed_times=[]; scan_times=[]
  7.times do |i|
    (i.even? ? [true,false] : [false,true]).each do |indexed|
      _,_,time=execute(indexed ? plan : plan.reject { |k,_| k=='indexDirectory' },paths)
      (indexed ? indexed_times : scan_times) << time
    end
  end
  warm_time=indexed_times.sort[3]; baseline_time=scan_times.sort[3]
  check(rows(cold).sort_by(&:to_s)==rows(warm).sort_by(&:to_s) && rows(warm).sort_by(&:to_s)==rows(baseline).sort_by(&:to_s),'Index changed results')
  check(warm_stats['filesSkippedByIndex']==31 && warm_stats['filesOpened']==1,'Warm index did not eliminate irrelevant reads')
  File.write(paths[0],File.read(paths[0]).sub('ordinary','uniqueneedle'))
  changed,changed_stats,=execute(plan,paths)
  check(rows(changed).size==2 && changed_stats['indexesUpdated']==1,'Changed file did not invalidate its signature')
  # Preserve size and mtime; ctime must still invalidate.
  timestamp=File.mtime(paths[1]); File.write(paths[1],File.read(paths[1]).sub('ordinary payload','uniqueneedle xyz')); File.utime(timestamp,timestamp,paths[1])
  check(rows(execute(plan,paths)[0]).size==3,'Same-size edit with restored mtime was missed')
  4.times.map { Thread.new { execute(plan,paths)[0] } }.map(&:value).each { |out| check(rows(out).size==3,'Concurrent query diverged') }
  summary=Dir.glob(File.join(cache,'content-v2','*','summary.bin')).first
  File.write(summary,'{broken')
  check(rows(execute(plan,paths)[0]).size==3,'Corrupt signature changed results')
  negatives=plan.merge('tree'=>{'none'=>[{'leaf'=>0}]},'positive'=>[],'fileUnit'=>true,'filesOnly'=>true)
  with=execute(negatives,paths)[0].split("\0").sort
  without=execute(negatives.reject { |k,_| k=='indexDirectory' },paths)[0].split("\0").sort
  check(with==without && with.length==29,'Negative query incorrectly excluded files')
  puts 'PASS: index parity, edits including restored mtime, corruption fallback, parallel queries, negative conditions'
  puts JSON.pretty_generate({'workload'=>'32 synthetic repetitive logs, about 70 MB; selective literal, 4 workers',
    'coldBuildSeconds'=>cold_time.round(4),'warmIndexedSeconds'=>warm_time.round(4),'warmScanSeconds'=>baseline_time.round(4),
    'warmCounters'=>warm_stats,'coldCounters'=>cold_stats})
end
