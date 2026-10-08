# Build provenance without developer paths, credentials, or machine names.
require 'json'
require 'digest'
require 'open3'
root,sdk=ARGV
Dir.chdir(root) do
  version=lambda do |*args|
    out,err,status=Open3.capture3(*args)
    raise err unless status.success?
    out.strip
  end
  files=%w[LICENSE docs/licenses/linguist-LICENSE.txt Package.swift Package.resolved Tools/findui-content/Cargo.toml Tools/findui-content/Cargo.lock Tools/search-tools.json Tools/language-type-source.json packaging/Info.plist .github/workflows/release.yml]
  files+=Dir.glob('Sources/**/*')+Dir.glob('Tools/findui-content/src/**/*')+%w[packaging/FindUI.svg packaging/FindUI.icns scripts/build_icon.sh scripts/release_rust_env.sh scripts/build_core.sh scripts/build_search_tools.sh scripts/build_app.sh scripts/build_info.rb scripts/collect_core_licenses.rb scripts/collect_search_tool_licenses.rb]
  inputs=files.select { |path|File.file?(path) }.uniq.sort.to_h { |path|[path,Digest::SHA256.file(path).hexdigest] }
  ci = if ENV['GITHUB_ACTIONS'] == 'true'
    repository = ENV.fetch('GITHUB_REPOSITORY')
    {provider:'GitHub Actions',repository:repository,commit:ENV.fetch('GITHUB_SHA'),
      runURL:"#{ENV.fetch('GITHUB_SERVER_URL')}/#{repository}/actions/runs/#{ENV.fetch('GITHUB_RUN_ID')}"}
  end
  puts JSON.pretty_generate({schemaVersion:1,inputs:inputs,sourceDigest:Digest::SHA256.hexdigest(JSON.generate(inputs)),
    swift:version.call('swift','--version'),rust:version.call('rustc','--version'),cargo:version.call('cargo','--version'),
    sdk:sdk,minimumMacOS:'14.0',configuration:'release',rustLTO:'thin',pcre2:'static',
    searchTools:JSON.parse(File.read('.build/search-tools/provenance.json')),go:version.call('go','version'),
    signing:'ad-hoc',ci:ci,note:'Input fingerprints identify this build; binary reproducibility across different SDKs or compilers is not promised.'}.compact)
end
