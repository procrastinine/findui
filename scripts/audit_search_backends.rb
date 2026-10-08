#!/usr/bin/env ruby
# Real, local integration fixtures. No network or GUI; no third-party Ruby gems.
require 'json'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'tool_paths'

repo = File.expand_path('..', __dir__)
worker = ENV.fetch('FINDUI_CONTENT', File.join(repo, '.build/content-worker/release/findui-content'))
tika = ENV['FINDUI_TIKA_JAR']
def run(*command, input: '', env: {}, chdir: nil)
  out, err, status = Open3.capture3(env, *command, stdin_data: input, **(chdir ? {chdir: chdir} : {}))
  raise "#{command.first}: #{err}" unless status.success?
  out
end
def check(value, message)
  raise message unless value
end
def pdf(path)
  objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
  stream = "BT /F1 16 Tf 72 720 Td (needle PDF document) Tj ET\n"
  objects << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"
  data = "%PDF-1.4\n"; offsets = [0]
  objects.each_with_index { |object, i| offsets << data.bytesize; data << "#{i+1} 0 obj\n#{object}\nendobj\n" }
  xref = data.bytesize
  data << "xref\n0 #{objects.length+1}\n0000000000 65535 f \n"
  offsets.drop(1).each { |offset| data << format('%010d 00000 n ', offset) + "\n" }
  data << "trailer\n<< /Size #{objects.length+1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  File.binwrite(path, data)
end
def office_zip(root, name, entries)
  folder = File.join(root, "#{name}-parts"); FileUtils.mkdir_p(folder)
  entries.each { |path, data| file = File.join(folder, path); FileUtils.mkdir_p(File.dirname(file)); File.write(file, data) }
  file = File.join(root, name)
  run('/usr/bin/zip', '-q', '-r', file, '.', chdir: folder)
  file
end

Dir.mktmpdir('findui-backends-') do |temporary|
  root = File.realpath(temporary)
  File.write(File.join(root, 'source.md'), "needle document\n")
  docx = File.join(root, 'report.docx'); odt = File.join(root, 'report.odt')
  [docx, odt].each { |file| run(findui_tool('pandoc'), File.join(root, 'source.md'), '-o', file) }
  pdf_file = File.join(root, 'report.pdf'); pdf(pdf_file)
  run('/usr/bin/zip', '-q', 'inner.zip', 'report.docx', chdir: root)
  run('/usr/bin/zip', '-q', 'outer.zip', 'inner.zip', 'report.pdf', chdir: root)
  run('/usr/bin/tar', '-czf', File.join(root, 'bundle.tar.gz'), '-C', root, 'report.odt')
  FileUtils.cp(File.join(root, 'bundle.tar.gz'), File.join(root, 'bundle.tgz'))
  html = File.join(root, 'report.htm'); File.write(html, '<html><body><p>needle HTML document</p></body></html>')
  run('/usr/bin/zip', '-q', '-P', 'fixture-password', 'encrypted.zip', 'report.docx', chdir: root)

  counter = File.join(root, 'pandoc-calls')
  wrapper = File.join(root, 'pandoc')
  File.write(wrapper, "#!/bin/sh\nprintf 'convert\\n' >> #{Shellwords.escape(counter)}\nexec #{Shellwords.escape(findui_tool('pandoc'))} \"$@\"\n")
  File.chmod(0700, wrapper)
  extraction = {'documents'=>true, 'archives'=>true, 'cacheDirectory'=>File.join(root, 'cache'),
    'maxDepth'=>5, 'maxMegabytes'=>64, 'timeoutSeconds'=>30,
    'pandoc'=>wrapper, 'pdftotext'=>findui_tool('pdftotext'), 'tikaJar'=>tika}
  plan = {'tree'=>{'leaf'=>0}, 'leaves'=>[{'pattern'=>'needle'}], 'positive'=>[0], 'threads'=>4, 'extraction'=>extraction}
  input_paths = [docx, odt, pdf_file, html, File.join(root,'outer.zip'), File.join(root,'bundle.tar.gz'), File.join(root,'bundle.tgz')]
  input = input_paths.join("\0") + "\0"
  first = run(worker, '--plan', JSON.generate(plan), input: input).lines.map { |line| JSON.parse(line) }
  check(first.length >= 6, "Missing document/archive matches: #{first}")
  check(first.map { |row| row['data']['path']['text'] }.uniq.sort == input_paths.sort, 'Missing a document/archive format')
  check(first.all? { |row| row['data']['line_number'].nil? && row['data']['findui_origin'] }, 'Extracted offsets presented as source lines')
  check(first.any? { |row| row['data']['findui_origin']['page'] == 1 }, 'Missing PDF page')
  check(first.any? { |row| row['data']['findui_origin'].fetch('members', []).any? { |member| member['name'] == 'inner.zip' } }, 'Missing structured nested member provenance')
  calls = File.readlines(counter).length
  second = run(worker, '--plan', JSON.generate(plan), input: input).lines.map { |line| JSON.parse(line) }
  check(second.sort_by(&:to_s) == first.sort_by(&:to_s), 'Warm results differ')
  check(File.readlines(counter).length == calls, 'Warm search repeated document conversion')
  plan['extraction']['cacheDirectory'] = nil
  run(worker, '--plan', JSON.generate(plan), input: docx + "\0")
  check(File.readlines(counter).length > calls, 'Cache bypass did not run converter')
  plan['extraction']['cacheDirectory'] = File.join(root, 'cache')
  File.write(File.join(root, 'broken.pdf'), 'not a PDF')
  ['broken.pdf', 'encrypted.zip'].each do |name|
    _, errors, status = Open3.capture3(worker, '--plan', JSON.generate(plan), stdin_data: File.join(root, name) + "\0")
    check(!status.success? && errors.include?('findui-skipped'), "Unreported extraction failure: #{name}")
  end
  run(worker, '--cache-clear', File.join(root, 'cache'))
  check(!File.exist?(File.join(root, 'cache')), 'Cache clear left document text')
  before_concurrent = File.readlines(counter).length
  2.times.map { Thread.new { run(worker, '--plan', JSON.generate(plan), input: docx + "\0") } }.each(&:value)
  check(File.readlines(counter).length == before_concurrent + 1, 'Concurrent searches repeated document conversion')
  puts "PASS: DOCX, ODT, HTML, PDF pages, nested ZIP, TAR.GZ/TGZ, sequential/concurrent cache reuse, bypass/clear, corrupt PDF, encrypted ZIP"

  limited = Marshal.load(Marshal.dump(plan))
  limited['extraction']['maxDepth'] = 0
  _, error, status = Open3.capture3(worker, '--plan', JSON.generate(limited), stdin_data: File.join(root, 'outer.zip') + "\0")
  check(!status.success? && error.include?('nesting depth'), 'Archive depth limit was silently ignored')
  slow = File.join(root, 'slow-pandoc')
  File.write(slow, "#!/bin/sh\nexec /bin/sleep 10\n"); File.chmod(0700, slow)
  limited['extraction'].merge!('maxDepth'=>5, 'pandoc'=>slow, 'timeoutSeconds'=>1, 'cacheDirectory'=>nil)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  _, error, status = Open3.capture3(worker, '--plan', JSON.generate(limited), stdin_data: docx + "\0")
  check(!status.success? && error.include?('timed out') && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 5,
    'Converter timeout did not stop the process tree promptly')
  oversized = File.join(root, 'oversized-pandoc')
  File.write(oversized, "#!/usr/bin/ruby\nSTDOUT.write('x' * (2 * 1024 * 1024))\n"); File.chmod(0700, oversized)
  limited['extraction'].merge!('pandoc'=>oversized, 'timeoutSeconds'=>30, 'maxMegabytes'=>1)
  _, error, status = Open3.capture3(worker, '--plan', JSON.generate(limited), stdin_data: docx + "\0")
  check(!status.success? && error.include?('size limit'), 'Extracted output limit was silently ignored')
  unrelated = File.join(root, 'unrelated'); FileUtils.mkdir_p(unrelated)
  File.write(File.join(unrelated, 'keep.txt'), 'keep')
  _, _, status = Open3.capture3(worker, '--cache-clear', unrelated)
  check(!status.success? && File.read(File.join(unrelated, 'keep.txt')) == 'keep', 'Cache clear accepted an unrelated directory')
  puts 'PASS: archive depth, converter timeout, output limit, owned-cache validation'

  if tika
    spreadsheet = office_zip(root, 'book.xlsx', {
      '[Content_Types].xml'=>'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
      '_rels/.rels'=>'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
      'xl/workbook.xml'=>'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Ledger" sheetId="1" r:id="rId1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels'=>'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
      'xl/worksheets/sheet1.xml'=>'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>needle spreadsheet</t></is></c></row></sheetData></worksheet>'
    })
    presentation = office_zip(root, 'slides.pptx', {
      '[Content_Types].xml'=>'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>',
      '_rels/.rels'=>'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>',
      'ppt/presentation.xml'=>'<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
      'ppt/_rels/presentation.xml.rels'=>'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>',
      'ppt/slides/slide1.xml'=>'<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>needle presentation</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'
    })
    rtf = File.join(root, 'legacy.rtf'); File.write(rtf, '{\rtf1\ansi needle legacy document\par}')
    rows = run(worker, '--plan', JSON.generate(plan), input: [spreadsheet, presentation, rtf].join("\0") + "\0").lines.map { |line| JSON.parse(line) }
    check(rows.map { |row| row['data']['path']['text'] }.uniq.length == 3, "Tika missed Office fixtures: #{rows.inspect}")
    check(rows.none? { |row| row['data']['lines']['text'].start_with?('Sheet Ledger:', 'Slide 1:') }, 'Location labels polluted searchable document text')
    check(rows.any? { |row| row['data']['findui_origin']['sheet'] == 'Ledger' }, 'Missing structured sheet location')
    check(rows.any? { |row| row['data']['findui_origin']['slide'] == 1 }, 'Missing structured slide location')
    puts 'PASS: Tika XLSX, PPTX and RTF with Office-only parser configuration'
  end
  if ENV['FINDUI_KEEP_FIXTURES']
    FileUtils.cp_r(root, ENV.fetch('FINDUI_KEEP_FIXTURES'))
  end
  if ENV['FINDUI_BINARY']
    binary = ENV.fetch('FINDUI_BINARY')
    state = {'query'=>'needle', 'mode'=>'contents', 'scopePath'=>root, 'refinements'=>{
      'additionalScopes'=>[], 'source'=>'filesystem', 'name'=>'report.docx', 'nameMatching'=>'exact',
      'path'=>'', 'pathMatching'=>'contains', 'extensions'=>'', 'excludedFiles'=>'', 'fileQuery'=>'',
      'wholeWords'=>false, 'matchingFilesOnly'=>false, 'contextLines'=>3, 'fuzzyFullPath'=>true, 'workers'=>4,
      'extraction'=>{'documents'=>true, 'archives'=>true, 'useTika'=>false, 'cacheText'=>false,
        'maximumArchiveDepth'=>5, 'maximumMegabytes'=>64, 'timeoutSeconds'=>30}}}
    raw_state = JSON.generate(state)
    rows = run(binary, '--cli', 'search', raw_state).lines.map { |line| JSON.parse(line) }
    check(rows.map { |row| File.realpath(row['data']['path']['text']) }.uniq == [File.realpath(docx)], "Packaged CLI missed the filtered DOCX: #{rows.inspect}")
    command = run(binary, '--cli', 'search', raw_state, '--print-command')
    check(command.include?(File.join(File.dirname(binary), 'findui-content')), 'Packaged CLI did not use its bundled worker')
    copied = run('/bin/bash', '--noprofile', '--norc', '-c', command).lines.map { |line| JSON.parse(line) }
    check(copied == rows, 'Copied command differs from packaged headless search')
    puts 'PASS: packaged CLI discovers its helper, extracts DOCX and reproduces its copied command'
  end
end
