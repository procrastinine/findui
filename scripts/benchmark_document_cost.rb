#!/usr/bin/env ruby
# Run audit_search_backends.rb with FINDUI_KEEP_FIXTURES first. No downloads.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'tool_paths'
fixtures = ARGV.fetch(0, File.expand_path('../.cache/document-cost-fixtures', __dir__))
worker = ENV.fetch('FINDUI_CONTENT', File.expand_path('../.build/content-worker/release/findui-content', __dir__))
jar = ENV.fetch('FINDUI_TIKA_JAR')
Dir.mktmpdir('findui-reader-cost-') do |root|
  paths = %w[report.pdf report.docx book.xlsx].map { |name| File.join(fixtures, name) }
  plain = File.join(root, 'plain.txt'); File.write(plain, "needle text\n")
  plan = {'leaves'=>[{'pattern'=>'needle'}], 'tree'=>{'leaf'=>0}, 'positive'=>[0], 'threads'=>4}
  measure = lambda do |query, inputs|
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3(worker, '--plan', JSON.generate(query), stdin_data: inputs.join("\0") + "\0")
    raise err unless status.success?
    raise 'Missing result' unless out.lines.size >= inputs.size
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
  med = ->(values) { values.sort[values.size/2].round(4) }
  result = {'plainTextSeconds'=>med.call(5.times.map { measure.call(plan, [plain]) }), 'documents'=>{}}
  paths.each do |path|
    cold=[]; warm=[]
    3.times do |i|
      options={'documents'=>true,'archives'=>false,'cacheDirectory'=>File.join(root,"#{File.extname(path)}-#{i}"),
        'maxDepth'=>5,'maxMegabytes'=>64,'timeoutSeconds'=>30,'pandoc'=>findui_tool('pandoc'),
        'pdftotext'=>findui_tool('pdftotext'),'tikaJar'=>jar}
      query=plan.merge('extraction'=>options)
      cold << measure.call(query,[path]); warm << measure.call(query,[path])
    end
    result['documents'][File.extname(path)]={'firstConversionSeconds'=>med.call(cold),'cachedSearchSeconds'=>med.call(warm)}
  end
  puts JSON.pretty_generate(result)
end
