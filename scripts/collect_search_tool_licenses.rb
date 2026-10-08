require 'json'
require 'digest'
require 'fileutils'
require 'open3'
root,licenses=ARGV
module_file=JSON.parse(File.read(File.join(root,'fzf-module.json')))
# `go list -m -json all` writes a sequence of JSON objects.
json=File.read(File.join(root,'go-modules.json'))
modules=JSON.parse('['+json.gsub(/}\s*\n\s*{/, '},{')+']')
notices=[]
modules.each do |m|
  next if m['Path']=='go' || m['Path']=='toolchain'
  dir=m['Dir'] || (m['Main'] && module_file['Dir'])
  unless dir
    out,err,status=Open3.capture3('go','mod','download','-json',m.fetch('Path')+'@'+m.fetch('Version'))
    raise err unless status.success?
    downloaded=JSON.parse(out)
    raise "Checksum differs for #{m['Path']}" if m['Sum'] && m['Sum']!=downloaded['Sum']
    dir=downloaded['Dir']
  end
  raise "Missing module source: #{m['Path']}" unless dir && File.directory?(dir)
  texts=%w[LICENSE* COPYING* NOTICE* UNLICENSE*].flat_map { |p|Dir.glob(File.join(dir,p)) }.select { |p|File.file?(p) }
  raise "Missing license for #{m['Path']}" if texts.empty?
  folder=File.join(licenses,'fzf',m['Path'].gsub('/','_')+'-'+(m['Version'] || module_file['Version']))
  FileUtils.mkdir_p(folder);texts.each { |p|FileUtils.cp(p,folder) }
  notices << "#{m['Path']} #{m['Version'] || module_file['Version']}\nhttps://#{m['Path']}\n#{m['Sum']}"
end
File.write(File.join(licenses,'fzf','THIRD_PARTY_NOTICES.txt'),notices.join("\n\n")+"\n")
provenance={versions:JSON.parse(File.read('Tools/search-tools.json')),goModules:modules.map { |m|m.slice('Path','Version','Sum','GoModSum') }}
provenance[:cargo]=%w[ripgrep fd-find].to_h do |crate|
  metadata=JSON.parse(File.read(File.join(root,"#{crate}-metadata.json")))
  package=metadata['packages'].find { |p|p['name']==crate }
  lock=File.join(File.dirname(package.fetch('manifest_path')),'Cargo.lock')
  [crate,{version:package['version'],cargoLockSHA256:Digest::SHA256.file(lock).hexdigest}]
end
File.write(File.join(root,'provenance.json'),JSON.pretty_generate(provenance)+"\n")
